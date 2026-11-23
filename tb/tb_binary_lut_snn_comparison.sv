/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

`timescale 1ns/1ps

module tb_binary_lut_snn_comparison;
    localparam int N = 16;
    localparam int MAX_ACTIONS = 1024;
    localparam int MAX_CYCLES = 4096;
    localparam int DRAIN_CYCLES = 64;
    localparam int CLASS0_PE = 14;
    localparam int CLASS1_PE = 15;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic [27:0] action_mem [0:MAX_ACTIONS-1];
    integer action_count;
    integer action_index = 0;
    integer cycle_index = 0;
    integer drain_cycles = 0;
    string stimulus_path;

    logic learning_enable = 1'b0;
    logic external_valid = 1'b0;
    logic [3:0] event_source = '0;
    logic [15:0] teacher_spike = '0;
    logic maintenance_tick = 1'b0;
    logic event_ready;
    logic [15:0] spikes;
    logic [79:0] packed_connection_counts;
    logic evaluation;
    logic [3:0] pattern_id;
    logic label;
    logic ready_sampled;
    logic event_accepted;
    logic checked_learned_topology = 1'b0;

    always #5 clk = ~clk;

    binary_lut_array_benchmark_top #(
        .N(N)
    ) binary_network (
        .clk(clk),
        .rst(rst),
        .learning_enable(learning_enable),
        .event_valid(external_valid),
        .event_source(event_source),
        .selected_pe('0),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .event_ready(event_ready),
        .spikes(spikes),
        .packed_connection_counts(packed_connection_counts)
    );

    initial begin
        for (int i = 0; i < MAX_ACTIONS; i++)
            action_mem[i] = '0;
        if (!$value$plusargs("STIM=%s", stimulus_path))
            $fatal(1, "missing +STIM=<file> argument");
        if (!$value$plusargs("ACTIONS=%d", action_count))
            $fatal(1, "missing +ACTIONS=<count> argument");
        if (action_count < 1 || action_count > MAX_ACTIONS)
            $fatal(1, "action count outside [1, %0d]", MAX_ACTIONS);
        $readmemh(stimulus_path, action_mem, 0, action_count-1);

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        $display("BCONFIG,%0d", N);

        while ((action_index < action_count ||
                drain_cycles < DRAIN_CYCLES) &&
               cycle_index < MAX_CYCLES) begin
            @(negedge clk);

            if (action_index < action_count) begin
                external_valid = action_mem[action_index][1];
                event_source = action_mem[action_index][5:2];
                teacher_spike = action_mem[action_index][21:6];
                maintenance_tick = action_mem[action_index][0];
                evaluation = action_mem[action_index][22];
                pattern_id = action_mem[action_index][26:23];
                label = action_mem[action_index][27];
                learning_enable = !evaluation;
            end else begin
                external_valid = 1'b0;
                event_source = '0;
                teacher_spike = '0;
                maintenance_tick = 1'b0;
                evaluation = 1'b0;
                pattern_id = '0;
                label = 1'b0;
                learning_enable = 1'b1;
            end

            #1;
            ready_sampled = event_ready;
            event_accepted = external_valid && ready_sampled;

            @(posedge clk);
            #1;
            if (evaluation && !checked_learned_topology) begin
                if (packed_connection_counts[CLASS0_PE*5 +: 5] != 5'd4 ||
                    packed_connection_counts[CLASS1_PE*5 +: 5] != 5'd4)
                    $fatal(1, "binary network did not learn all class features");
                checked_learned_topology = 1'b1;
            end

            $display(
                "BTRACE,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%04h,%0d,%0d",
                cycle_index,
                action_index,
                evaluation,
                pattern_id,
                label,
                external_valid,
                event_source,
                ready_sampled,
                event_accepted,
                spikes,
                packed_connection_counts[CLASS0_PE*5 +: 5],
                packed_connection_counts[CLASS1_PE*5 +: 5]
            );

            if (action_index < action_count &&
                (!external_valid || ready_sampled))
                action_index = action_index + 1;
            else if (action_index == action_count)
                drain_cycles = drain_cycles + 1;
            cycle_index = cycle_index + 1;
        end

        if (action_index != action_count)
            $fatal(1, "binary network accepted %0d/%0d actions",
                   action_index, action_count);
        if (!checked_learned_topology)
            $fatal(1, "binary network did not reach held-out evaluation");
        $display("BEND,%0d", cycle_index);
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "binary SNN classification comparison timed out");
    end
endmodule
