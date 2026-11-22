/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module binary_lut_array #(
    parameter int N = 16,
    parameter int FIFO_DEPTH = 64
) (
    input  logic clk,
    input  logic rst,
    input  logic learning_enable,
    input  logic event_valid,
    input  logic [$clog2(N)-1:0] event_source,
    input  logic [N-1:0] teacher_spike,
    input  logic maintenance_tick,
    output logic event_ready,
    output logic event_overflow,
    output logic [N-1:0] spikes,
    output logic [N*5-1:0] packed_connection_counts
);
    localparam int ID_W = $clog2(N);
    localparam int LEVEL_W = $clog2(FIFO_DEPTH + 1);

    logic routed_event_valid;
    logic [ID_W-1:0] routed_event_source;
    logic [LEVEL_W-1:0] event_fifo_level;

    function automatic logic [4:0] count_connections(
        input logic [N-1:0] mask
    );
        logic [4:0] total;
        begin
            total = '0;
            for (int i = 0; i < N; i++) begin
                if (mask[i])
                    total = total + 5'd1;
            end
            count_connections = total;
        end
    endfunction

    eap16_event_router #(
        .N(N),
        .FIFO_DEPTH(FIFO_DEPTH)
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
        .level(event_fifo_level)
    );

    for (genvar g = 0; g < N; g++) begin : gen_pe
        logic [N-1:0] connections;

        binary_lut_pe #(
            .PE_ID(g),
            .N(N)
        ) u_pe (
            .clk(clk),
            .rst(rst),
            .learning_enable(learning_enable),
            .event_valid(routed_event_valid),
            .event_source(routed_event_source),
            .teacher_spike(teacher_spike[g]),
            .maintenance_tick(maintenance_tick),
            .spike(spikes[g]),
            .membrane_state(),
            .synapse_mask(connections)
        );

        assign packed_connection_counts[g*5 +: 5] =
            count_connections(connections);
    end
endmodule
