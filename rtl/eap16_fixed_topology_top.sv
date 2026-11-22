/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module eap16_fixed_topology_pe #(
    parameter int PE_ID = 0,
    parameter int N = 16,
    parameter int WEIGHT_W = 8,
    parameter logic signed [23:0] THRESHOLD = 24'sd1000,
    // Match the adaptive PE's width-scaled default excitation.
    parameter logic signed [WEIGHT_W-1:0] FIXED_WEIGHT =
        (WEIGHT_W >= 8) ? WEIGHT_W'(8) :
        (WEIGHT_W >= 7) ? WEIGHT_W'(4) :
        (WEIGHT_W >= 6) ? WEIGHT_W'(2) : WEIGHT_W'(1),
    parameter logic [N-1:0] SOURCE_MASK = '0
) (
    input  logic clk,
    input  logic rst,
    input  logic event_valid,
    input  logic [$clog2(N)-1:0] event_source,
    input  logic teacher_spike,
    output logic spike,
    output logic [$clog2(N+1)-1:0] connection_count
);
    localparam int ID_W = $clog2(N);

    logic signed [23:0] membrane;
    logic signed [23:0] synaptic_current;
    logic signed [23:0] next_membrane;
    logic will_spike;

    always_comb begin
        synaptic_current = '0;
        connection_count = '0;
        for (int source = 0; source < N; source++) begin
            if (SOURCE_MASK[source] && source != PE_ID) begin
                connection_count = connection_count + 1'b1;
                if (event_valid && event_source == ID_W'(source))
                    synaptic_current =
                        {{(24-WEIGHT_W){FIXED_WEIGHT[WEIGHT_W-1]}},
                          FIXED_WEIGHT};
            end
        end

        next_membrane = membrane - (membrane >>> 4) + synaptic_current;
        will_spike = teacher_spike ||
                     (event_valid && next_membrane >= THRESHOLD);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            membrane <= '0;
            spike <= 1'b0;
        end else begin
            spike <= will_spike;
            if (will_spike)
                membrane <= '0;
            else
                membrane <= next_membrane;
        end
    end
endmodule

module eap16_fixed_topology_top #(
    parameter int N = 16,
    parameter int EVENT_FIFO_DEPTH = 64,
    parameter int WEIGHT_W = 8,
    parameter logic signed [23:0] THRESHOLD = 24'sd1000,
    // Keep the fixed-network default consistent with its PE parameter.
    parameter logic signed [WEIGHT_W-1:0] FIXED_WEIGHT =
        (WEIGHT_W >= 8) ? WEIGHT_W'(8) :
        (WEIGHT_W >= 7) ? WEIGHT_W'(4) :
        (WEIGHT_W >= 6) ? WEIGHT_W'(2) : WEIGHT_W'(1),
    parameter logic [N*N-1:0] TOPOLOGY_MASK = '0
) (
    input  logic clk,
    input  logic rst,
    input  logic event_valid,
    input  logic [$clog2(N)-1:0] event_source,
    input  logic [N-1:0] teacher_spike,
    input  logic maintenance_tick,
    output logic event_ready,
    output logic event_overflow,
    output logic [N-1:0] spikes,
    output logic [N*5-1:0] packed_connection_counts
);
    // Fixed topology has no traces or idle ages to update on maintenance ticks.
    localparam int ID_W = $clog2(N);

    logic routed_event_valid;
    logic [ID_W-1:0] routed_event_source;

    eap16_event_router #(
        .N(N),
        .FIFO_DEPTH(EVENT_FIFO_DEPTH)
    ) event_router (
        .clk(clk),
        .rst(rst),
        .external_valid(event_valid),
        .external_source(event_source),
        .external_ready(event_ready),
        .feedback_spikes(spikes),
        .event_valid(routed_event_valid),
        .event_source(routed_event_source),
        .event_consume(routed_event_valid),
        .overflow(event_overflow),
        .level()
    );

    for (genvar g = 0; g < N; g++) begin : gen_fixed_pe
        localparam logic [N-1:0] SOURCE_MASK =
            TOPOLOGY_MASK[g*N +: N];
        logic [$clog2(N+1)-1:0] count;

        eap16_fixed_topology_pe #(
            .PE_ID(g),
            .N(N),
            .WEIGHT_W(WEIGHT_W),
            .THRESHOLD(THRESHOLD),
            .FIXED_WEIGHT(FIXED_WEIGHT),
            .SOURCE_MASK(SOURCE_MASK)
        ) u_pe (
            .clk(clk),
            .rst(rst),
            .event_valid(routed_event_valid),
            .event_source(routed_event_source),
            .teacher_spike(teacher_spike[g]),
            .spike(spikes[g]),
            .connection_count(count)
        );

        assign packed_connection_counts[g*5 +: 5] = 5'(count);
    end

endmodule
