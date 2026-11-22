// EAP-16 dynamic processing element.
module eap_dynamic_pe #(
    parameter int PE_ID = 0,
    parameter int N = 16,
    parameter int FANIN = 16,
    parameter int WEIGHT_W = 8,
    parameter int IDLE_W = 8,
    parameter logic signed [23:0] THRESHOLD = 24'sd1000,
    parameter logic [7:0] FORM_THRESHOLD = 8'd8,
    // Scale the default with signed full scale, keeping narrow weights nonzero.
    parameter logic signed [WEIGHT_W-1:0] INITIAL_WEIGHT =
        (WEIGHT_W >= 8) ? WEIGHT_W'(8) :
        (WEIGHT_W >= 7) ? WEIGHT_W'(4) :
        (WEIGHT_W >= 6) ? WEIGHT_W'(2) : WEIGHT_W'(1),
    parameter logic signed [WEIGHT_W-1:0] MIN_WEIGHT =
        (WEIGHT_W >= 3) ? WEIGHT_W'(2) : WEIGHT_W'(1),
    parameter logic [IDLE_W-1:0] PRUNE_AGE =
        (IDLE_W >= 8) ? IDLE_W'(8'd200) : {IDLE_W{1'b1}}
) (
    input  logic clk,
    input  logic rst,
    input  logic learning_enable,
    input  logic event_valid,
    input  logic [$clog2(N)-1:0] event_source,
    input  logic teacher_spike,
    input  logic maintenance_tick,
    output logic spike,
    output logic [$clog2(FANIN+1)-1:0] connection_count
);

    localparam int ID_W = $clog2(N);
    localparam logic signed [WEIGHT_W-1:0] WEIGHT_MAX =
        {1'b0, {(WEIGHT_W-1){1'b1}}};
    localparam logic signed [WEIGHT_W-1:0] WEIGHT_MIN = -WEIGHT_MAX;
    localparam logic [IDLE_W-1:0] IDLE_MAX = {IDLE_W{1'b1}};

    logic [FANIN-1:0] syn_valid;
    logic [ID_W-1:0] syn_source [0:FANIN-1];
    logic signed [WEIGHT_W-1:0] syn_weight [0:FANIN-1];
    logic [IDLE_W-1:0] syn_idle [0:FANIN-1];

    logic [7:0] candidate_pre [0:N-1];
    logic [N-1:0] candidate_active;
    logic [7:0] post_trace;
    logic [N-1:0] pending;
    logic [N-1:0] connected_sources;

    logic signed [23:0] membrane;
    logic signed [23:0] syn_current;
    logic signed [WEIGHT_W-1:0] event_weight;
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

        // Unique source IDs bound one event's current to the selected weight.
        syn_current =
            {{(24-WEIGHT_W){event_weight[WEIGHT_W-1]}}, event_weight};
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

            if (learning_enable) begin
                // Candidate traces update the active source and decay on ticks.
                for (i = 0; i < N; i = i + 1) begin
                    if (event_valid && event_source == ID_W'(i) &&
                        i != PE_ID) begin
                        if (candidate_pre[i] != 8'hff)
                            candidate_pre[i] <= candidate_pre[i] + 1'b1;
                    end else if (maintenance_tick && candidate_pre[i] != 0) begin
                        candidate_pre[i] <= (candidate_pre[i] > 8'd15)
                                          ? candidate_pre[i] -
                                            (candidate_pre[i] >> 4)
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

                // Existing synapses refresh age and apply bounded STDP updates.
                for (i = 0; i < FANIN; i = i + 1) begin
                    if (syn_valid[i]) begin
                        if (event_valid && syn_source[i] == event_source) begin
                            syn_idle[i] <= '0;
                        end else if (maintenance_tick &&
                                     syn_idle[i] != IDLE_MAX) begin
                            syn_idle[i] <= syn_idle[i] + 1'b1;
                        end

                        // Potentiation wins when pre- and post-updates coincide.
                        if (will_spike && candidate_active[syn_source[i]]) begin
                            if (syn_weight[i] < WEIGHT_MAX)
                                syn_weight[i] <= syn_weight[i] + WEIGHT_W'(1);
                        end else if (event_valid &&
                                     syn_source[i] == event_source &&
                                     post_trace != 0) begin
                            if (syn_weight[i] > WEIGHT_MIN)
                                syn_weight[i] <= syn_weight[i] - WEIGHT_W'(1);
                        end

                        if (maintenance_tick &&
                            !(event_valid && syn_source[i] == event_source) &&
                            syn_idle[i] >= PRUNE_AGE &&
                            ((syn_weight[i] >= 0 &&
                              syn_weight[i] < MIN_WEIGHT) ||
                             (syn_weight[i] < 0 &&
                              syn_weight[i] > -MIN_WEIGHT))) begin
                            syn_valid[i] <= 1'b0;
                            pending[syn_source[i]] <= 1'b0;
                        end
                    end
                end

                // A post-spike queues active unconnected sources for formation.
                if (will_spike) begin
                    for (i = 0; i < N; i = i + 1) begin
                        if (i != PE_ID &&
                            candidate_pre[i] >= FORM_THRESHOLD &&
                            !connected_sources[i])
                            pending[i] <= 1'b1;
                    end
                end

                // Allocate at most one pending connection per cycle.
                if (free_slot != -1 && pending_source != -1) begin
                    syn_valid[free_slot] <= 1'b1;
                    syn_source[free_slot] <= ID_W'(pending_source);
                    syn_weight[free_slot] <= INITIAL_WEIGHT;
                    syn_idle[free_slot] <= '0;
                    pending[pending_source] <= 1'b0;
                end
            end
        end
    end

endmodule
