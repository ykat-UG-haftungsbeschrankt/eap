// EAP-16 dynamic processing element.
module eap_dynamic_pe #(
    parameter int PE_ID = 0,
    parameter int N = 16,
    parameter int FANIN = 16,
    parameter logic signed [23:0] THRESHOLD = 24'sd1000,
    parameter logic [7:0] FORM_THRESHOLD = 8'd8,
    parameter logic [7:0] PRUNE_AGE = 8'd200,
    parameter logic signed [7:0] MIN_WEIGHT = 8'sd2
) (
    input  logic clk,
    input  logic rst,
    input  logic event_valid,
    input  logic [$clog2(N)-1:0] event_source,
    input  logic teacher_spike,
    input  logic maintenance_tick,
    output logic spike,
    output logic [$clog2(FANIN+1)-1:0] connection_count
);

    localparam int ID_W = $clog2(N);
    logic [FANIN-1:0] syn_valid;
    logic [ID_W-1:0] syn_source [0:FANIN-1];
    logic signed [7:0] syn_weight [0:FANIN-1];
    logic [7:0] syn_idle [0:FANIN-1];

    logic [7:0] candidate_pre [0:N-1];
    logic [N-1:0] candidate_active;
    logic [7:0] post_trace;
    logic [N-1:0] pending;
    logic [N-1:0] connected_sources;

    logic signed [23:0] membrane;
    logic signed [23:0] syn_current;
    logic signed [7:0] event_weight;
    logic signed [23:0] next_membrane;
    logic will_spike;
    logic event_weight_found;

    integer i;
    integer free_slot;
    integer pending_source;
    integer count_tmp;

    always_comb begin
        syn_current = '0;
        event_weight = '0;
        event_weight_found = 1'b0;
        free_slot = -1;
        pending_source = -1;
        count_tmp = 0;
        connected_sources = '0;
        candidate_active = '0;

        for (int s = 0; s < FANIN; s++) begin
            if (syn_valid[s]) begin
                count_tmp = count_tmp + 1;
                connected_sources[syn_source[s]] = 1'b1;
                // Formation keeps source IDs unique, so only one weight can match.
                if (event_valid && syn_source[s] == event_source &&
                    !event_weight_found) begin
                    event_weight = syn_weight[s];
                    event_weight_found = 1'b1;
                end
            end else if (free_slot == -1) begin
                free_slot = s;
            end
        end

        for (int c = 0; c < N; c++)
            candidate_active[c] = (candidate_pre[c] != 0);

        for (int p = 0; p < N; p++) begin
            if (pending[p] && pending_source == -1)
                pending_source = p;
        end

        // With FANIN <= 16 and weights in [-127, 127], syn_current is
        // bounded to +/-2032 and the leak keeps this 24-bit update in range.
        syn_current = {{16{event_weight[7]}}, event_weight};
        next_membrane = membrane - (membrane >>> 4) + syn_current;
        will_spike = teacher_spike || (event_valid && next_membrane >= THRESHOLD);
        connection_count = count_tmp[$clog2(FANIN+1)-1:0];
    end

    // Trace eligibility uses pre-update values; simultaneous learning updates
    // are resolved explicitly in the synapse loop below.
    always_ff @(posedge clk) begin
        if (rst) begin
            membrane <= '0;
            spike <= 1'b0;
            post_trace <= '0;
            pending <= '0;
            syn_valid <= '0;
            for (i = 0; i < N; i = i + 1)
                candidate_pre[i] <= '0;
            for (i = 0; i < FANIN; i = i + 1) begin
                syn_source[i] <= '0;
                syn_weight[i] <= '0;
                syn_idle[i] <= '0;
            end
        end else begin
            spike <= 1'b0;

            if (will_spike) begin
                spike <= 1'b1;
                membrane <= '0;
            end else begin
                membrane <= next_membrane;
            end

            // Candidate traces: update the active source; decay every other
            // candidate on maintenance ticks, independent of event traffic.
            for (i = 0; i < N; i = i + 1) begin
                if (event_valid && event_source == ID_W'(i) && i != PE_ID) begin
                    if (candidate_pre[i] != 8'hff)
                        candidate_pre[i] <= candidate_pre[i] + 1'b1;
                end else if (maintenance_tick && candidate_pre[i] != 0) begin
                    candidate_pre[i] <= (candidate_pre[i] > 8'd15)
                                      ? candidate_pre[i] - (candidate_pre[i] >> 4)
                                      : candidate_pre[i] - 1'b1;
                end
            end

            // Post trace has its own clocking/decay path.
            if (will_spike) begin
                if (post_trace != 8'hff)
                    post_trace <= post_trace + 1'b1;
            end else if (maintenance_tick && post_trace != 0) begin
                post_trace <= (post_trace > 8'd15)
                            ? post_trace - (post_trace >> 4)
                            : post_trace - 1'b1;
            end

            // Existing synapses: activity refreshes age; simultaneous weight
            // updates use explicit potentiation priority.
            for (i = 0; i < FANIN; i = i + 1) begin
                if (syn_valid[i]) begin
                    if (event_valid && syn_source[i] == event_source) begin
                        syn_idle[i] <= '0;
                    end else if (maintenance_tick && syn_idle[i] != 8'hff) begin
                        syn_idle[i] <= syn_idle[i] + 1'b1;
                    end

                    // Potentiation has priority if pre- and post-updates coincide.
                    if (will_spike && candidate_active[syn_source[i]]) begin
                        if (syn_weight[i] < 8'sd127)
                            syn_weight[i] <= syn_weight[i] + 1'b1;
                    end else if (event_valid && syn_source[i] == event_source &&
                                 post_trace != 0) begin
                        if (syn_weight[i] > -8'sd127)
                            syn_weight[i] <= syn_weight[i] - 1'b1;
                    end

                    if (maintenance_tick &&
                        !(event_valid && syn_source[i] == event_source) &&
                        syn_idle[i] >= PRUNE_AGE &&
                        ((syn_weight[i] >= 0 && syn_weight[i] < MIN_WEIGHT) ||
                         (syn_weight[i] < 0 && syn_weight[i] > -MIN_WEIGHT))) begin
                        syn_valid[i] <= 1'b0;
                        pending[syn_source[i]] <= 1'b0;
                    end
                end
            end

            // On a postsynaptic spike, mark active unconnected sources pending.
            if (will_spike) begin
                for (i = 0; i < N; i = i + 1) begin
                    if (i != PE_ID && candidate_pre[i] >= FORM_THRESHOLD &&
                        !connected_sources[i])
                        pending[i] <= 1'b1;
                end
            end

            // Allocate at most one pending connection per cycle.
            if (free_slot != -1 && pending_source != -1) begin
                syn_valid[free_slot] <= 1'b1;
                syn_source[free_slot] <= ID_W'(pending_source);
                syn_weight[free_slot] <= 8'sd8;
                syn_idle[free_slot] <= '0;
                pending[pending_source] <= 1'b0;
            end
        end
    end

endmodule
