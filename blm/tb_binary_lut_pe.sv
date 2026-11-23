/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

`timescale 1ns/1ps

module tb_binary_lut_pe;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic learning_enable = 1'b0;
    logic snapshot_pause = 1'b0;
    logic snapshot_state_word = 1'b0;
    logic snapshot_write_enable = 1'b0;
    logic [31:0] snapshot_write_data = '0;
    logic [31:0] snapshot_read_data;
    logic event_valid = 1'b0;
    logic [3:0] event_source = '0;
    logic [15:0] event_source_onehot;
    logic teacher_spike = 1'b0;
    logic maintenance_tick = 1'b0;
    logic spike;
    logic [1:0] membrane_state;
    logic [15:0] synapse_mask;

    always #5 clk = ~clk;

    always_comb begin
        event_source_onehot = '0;
        if (event_valid)
            event_source_onehot[event_source] = 1'b1;
    end

    binary_lut_pe #(
        .PE_ID(1),
        .N(16)
    ) dut (
        .clk(clk),
        .rst(rst),
        .learning_enable(learning_enable),
        .snapshot_pause(snapshot_pause),
        .snapshot_state_word(snapshot_state_word),
        .snapshot_write_enable(snapshot_write_enable),
        .snapshot_write_data(snapshot_write_data),
        .snapshot_read_data(snapshot_read_data),
        .event_source_onehot(event_source_onehot),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .spike(spike),
        .membrane_state(membrane_state),
        .synapse_mask(synapse_mask)
    );

    task automatic cycle(
        input logic learn,
        input logic valid,
        input logic [3:0] source,
        input logic teacher,
        input logic maintenance
    );
        begin
            @(negedge clk);
            learning_enable = learn;
            event_valid = valid;
            event_source = source;
            teacher_spike = teacher;
            maintenance_tick = maintenance;
            @(posedge clk);
            #1;
            event_valid = 1'b0;
            teacher_spike = 1'b0;
            maintenance_tick = 1'b0;
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        #1;
        if (spike !== 1'b0 || membrane_state !== 2'b00 ||
            synapse_mask !== 16'b0)
            $fatal(1, "reset state was not clear");

        @(negedge clk);
        rst = 1'b0;

        repeat (3) cycle(1'b1, 1'b1, 4'd1, 1'b0, 1'b0);
        if (dut.candidate_pre[1] !== 1'b0)
            $fatal(1, "self source updated its pre-trace");
        cycle(1'b1, 1'b0, 4'd0, 1'b1, 1'b0);
        if (synapse_mask !== 16'b0)
            $fatal(1, "self-connection was formed");

        cycle(1'b1, 1'b1, 4'd0, 1'b0, 1'b0);
        if (dut.candidate_pre[0] !== 1'b1 ||
            membrane_state !== 2'b00)
            $fatal(1, "binary-synapse pre-trace did not accumulate");
        cycle(1'b1, 1'b0, 4'd0, 1'b1, 1'b0);
        if (spike !== 1'b1 || synapse_mask !== 16'h0001 ||
            membrane_state !== 2'b00)
            $fatal(1, "post-spike did not form a binary synapse");

        cycle(1'b0, 1'b1, 4'd0, 1'b0, 1'b1);
        if (membrane_state !== 2'b01 || spike !== 1'b0)
            $fatal(1, "synaptic event did not win over simultaneous leak");
        cycle(1'b0, 1'b0, 4'd0, 1'b0, 1'b1);
        if (membrane_state !== 2'b00)
            $fatal(1, "LUT membrane did not leak on maintenance tick");

        cycle(1'b0, 1'b1, 4'd0, 1'b0, 1'b0);
        if (membrane_state !== 2'b01 || spike !== 1'b0)
            $fatal(1, "LUT membrane 0->1 transition failed");
        cycle(1'b0, 1'b1, 4'd0, 1'b0, 1'b0);
        if (membrane_state !== 2'b10 || spike !== 1'b0)
            $fatal(1, "LUT membrane 1->2 transition failed");
        cycle(1'b0, 1'b1, 4'd0, 1'b0, 1'b0);
        if (membrane_state !== 2'b00 || spike !== 1'b1)
            $fatal(1, "LUT membrane threshold did not spike and reset");
        cycle(1'b0, 1'b0, 4'd0, 1'b0, 1'b0);
        if (spike !== 1'b0)
            $fatal(1, "spike output was not a one-cycle pulse");

        cycle(1'b1, 1'b1, 4'd0, 1'b1, 1'b0);
        if (synapse_mask[0] !== 1'b1 || spike !== 1'b1)
            $fatal(1, "simultaneous potentiation did not win over depression");
        cycle(1'b1, 1'b1, 4'd0, 1'b0, 1'b0);
        if (synapse_mask !== 16'b0)
            $fatal(1, "recent-post depression did not disconnect the synapse");

        $display("PASS: binary synapses and LUT-driven membrane PE");
        $finish;
    end
endmodule
