/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module binary_lut_pe #(
    parameter int PE_ID = 0,
    parameter int N = 16
) (
    input  logic clk,
    input  logic rst,
    input  logic learning_enable,
    input  logic snapshot_pause,
    input  logic snapshot_write_word0,
    input  logic snapshot_write_word1,
    input  logic [31:0] snapshot_write_data,
    output logic [2*N-1:0] snapshot_read_word0,
    output logic [3:0] snapshot_read_word1,
    // Multiple source bits may be set; simultaneous events are combined.
    input  logic [N-1:0] event_source_mask,
    input  logic teacher_spike,
    input  logic maintenance_tick,
    output logic spike,
    output logic [1:0] membrane_state,
    output logic [N-1:0] synapse_mask
);
    localparam logic [N-1:0] SELF_MASK = N'(1) << PE_ID;
    localparam logic [N-1:0] NONSELF_MASK = ~SELF_MASK;

    logic [N-1:0] synapse_on;
    logic [N-1:0] synapse_next;
    logic [N-1:0] source_match;
    logic [N-1:0] pre_event_mask;
    logic [N-1:0] formation_mask;
    logic [N-1:0] depression_mask;
    logic [N-1:0] candidate_pre;
    logic [N-1:0] candidate_pre_next;
    logic post_recent;
    logic synaptic_input;
    logic [1:0] membrane_next;
    logic will_spike;

    always @* begin
        snapshot_read_word0 = {candidate_pre, synapse_on};
        snapshot_read_word1 = {spike, post_recent, membrane_state};
    end

    always @* begin
        source_match = event_source_mask;
        synaptic_input = |(source_match & synapse_on);
        will_spike = teacher_spike ||
                     (membrane_state == 2'b11) ||
                     ((membrane_state == 2'b10) && synaptic_input);
        membrane_next = membrane_state;
        if (synaptic_input)
            membrane_next = membrane_state + 2'd1;
        else if (maintenance_tick && (membrane_state != 2'b00))
            membrane_next = membrane_state - 2'd1;
        pre_event_mask = source_match & NONSELF_MASK;
        formation_mask =
            {N{will_spike}} & candidate_pre & NONSELF_MASK;
        depression_mask =
            {N{post_recent}} & pre_event_mask;
        synapse_next = (synapse_on & ~depression_mask) | formation_mask;
        candidate_pre_next =
            (candidate_pre & {N{!maintenance_tick}}) | pre_event_mask;
    end

    assign synapse_mask = synapse_on;

    always_ff @(posedge clk) begin
        if (rst) begin
            membrane_state <= 2'b00;
            spike <= 1'b0;
            synapse_on <= '0;
            post_recent <= 1'b0;
            candidate_pre <= '0;
        end else begin
            if (snapshot_write_word0) begin
                synapse_on <= snapshot_write_data[N-1:0];
                candidate_pre <= snapshot_write_data[2*N-1:N];
            end else if (!snapshot_pause && learning_enable) begin
                synapse_on <= synapse_next;
                candidate_pre <= candidate_pre_next;
            end

            if (snapshot_write_word1) begin
                membrane_state <= snapshot_write_data[1:0];
                post_recent <= snapshot_write_data[2];
                spike <= snapshot_write_data[3];
            end else if (!snapshot_pause) begin
                spike <= will_spike;
                if (will_spike)
                    membrane_state <= 2'b00;
                else
                    membrane_state <= membrane_next;

                if (learning_enable) begin
                    if (will_spike)
                        post_recent <= 1'b1;
                    else if (maintenance_tick)
                        post_recent <= 1'b0;
                end
            end
        end
    end
endmodule
