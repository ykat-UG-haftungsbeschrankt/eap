/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module binary_lut_pe #(
    parameter int PE_ID = 0,
    parameter int N = 16,
    parameter bit SNAPSHOT_ACCESS = 1'b0
) (
    input  logic clk,
    input  logic rst,
    input  logic learning_enable,
    input  logic snapshot_pause,
    input  logic snapshot_shift,
    input  logic snapshot_in,
    output logic snapshot_out,
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
    localparam int PE_STATE_BITS = 2*(N - 1) + 4;

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
    logic [PE_STATE_BITS-1:0] scan_state;
    logic [PE_STATE_BITS-1:0] scan_next;
    logic scan_shift_active;

    assign scan_shift_active =
        SNAPSHOT_ACCESS && snapshot_pause && snapshot_shift;

    // Pack only real state bits (excluding the permanently-zero self bit):
    // [0 .. N-2]: non-self synapse_on
    // [N-1 .. 2*(N-1)-1]: non-self candidate_pre
    // [2*(N-1) +: 4]: {spike, post_recent, membrane_state}
    always @* begin
        int idx;
        idx = 0;
        for (int i = 0; i < N; i++) begin
            if (i != PE_ID) begin
                scan_state[idx] = synapse_on[i];
                scan_state[(N - 1) + idx] = candidate_pre[i];
                idx = idx + 1;
            end
        end
        scan_state[2*(N - 1) +: 4] = {spike, post_recent, membrane_state};
        scan_next = {scan_state[PE_STATE_BITS-2:0], snapshot_in};
    end

    assign snapshot_out = SNAPSHOT_ACCESS ? scan_state[PE_STATE_BITS-1] : 1'b0;

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
        synapse_next =
            ((synapse_on & ~depression_mask) | formation_mask) &
            NONSELF_MASK;
        candidate_pre_next =
            ((candidate_pre & {N{!maintenance_tick}}) | pre_event_mask) &
            NONSELF_MASK;
    end

    assign synapse_mask = synapse_on;

    always_ff @(posedge clk) begin
        if (rst) begin
            membrane_state <= 2'b00;
            spike <= 1'b0;
            synapse_on <= '0;
            post_recent <= 1'b0;
            candidate_pre <= '0;
        end else if (scan_shift_active) begin
            int idx;
            idx = 0;
            for (int i = 0; i < N; i++) begin
                if (i == PE_ID) begin
                    synapse_on[i] <= 1'b0;
                    candidate_pre[i] <= 1'b0;
                end else begin
                    synapse_on[i] <= scan_next[idx];
                    candidate_pre[i] <= scan_next[(N - 1) + idx];
                    idx = idx + 1;
                end
            end
            membrane_state <= scan_next[2*(N - 1) +: 2];
            post_recent <= scan_next[2*(N - 1) + 2];
            spike <= scan_next[2*(N - 1) + 3];
        end else if (!(SNAPSHOT_ACCESS && snapshot_pause)) begin
            spike <= will_spike;
            if (will_spike)
                membrane_state <= 2'b00;
            else
                membrane_state <= membrane_next;

            if (learning_enable) begin
                synapse_on <= synapse_next;
                candidate_pre <= candidate_pre_next;

                if (will_spike)
                    post_recent <= 1'b1;
                else if (maintenance_tick)
                    post_recent <= 1'b0;
            end
        end
    end
endmodule
