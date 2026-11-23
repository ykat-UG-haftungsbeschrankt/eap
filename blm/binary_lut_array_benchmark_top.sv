/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module binary_lut_array_benchmark_top #(
    parameter int N = 16,
    parameter int FIFO_DEPTH = 64
) (
    input  logic clk,
    input  logic rst,
    input  logic learning_enable,
    input  logic event_valid,
    input  logic [$clog2(N)-1:0] event_source,
    input  logic [$clog2(N)-1:0] selected_pe,
    input  logic [N-1:0] teacher_spike,
    input  logic maintenance_tick,
    output logic event_ready,
    output logic event_overflow,
    output logic [N-1:0] spikes,
    output logic [N*5-1:0] packed_connection_counts
);
    binary_lut_array #(
        .N(N),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) network (
        .clk(clk),
        .rst(rst),
        .snapshot_pause(1'b0),
        .snapshot_addr('0),
        .snapshot_write_enable(1'b0),
        .snapshot_write_data(32'b0),
        .snapshot_read_data(),
        .snapshot_write_ready(),
        .learning_enable(learning_enable),
        .event_valid(event_valid),
        .event_source(event_source),
        .selected_pe(selected_pe),
        .synapse_map(),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .event_ready(event_ready),
        .event_overflow(event_overflow),
        .spikes(spikes),
        .packed_connection_counts(packed_connection_counts)
    );
endmodule
