/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

`timescale 1ns/1ps

module tb_snn_comparison;
    localparam int N = 16;
    localparam int MAX_ACTIONS = 1024;
    localparam int MAX_CYCLES = 4096;
    localparam int CLASS0_PE = 14;
    localparam int CLASS1_PE = 15;
    localparam logic signed [23:0] TEST_THRESHOLD = 24'sd100;
    localparam logic signed [7:0] FIXED_WEIGHT = 8'sd8;
    localparam logic [N*N-1:0] FIXED_TOPOLOGY =
        (256'b1 << (CLASS0_PE*N + 0)) |
        (256'b1 << (CLASS0_PE*N + 1)) |
        (256'b1 << (CLASS0_PE*N + 2)) |
        (256'b1 << (CLASS0_PE*N + 3)) |
        (256'b1 << (CLASS1_PE*N + 4)) |
        (256'b1 << (CLASS1_PE*N + 5)) |
        (256'b1 << (CLASS1_PE*N + 6)) |
        (256'b1 << (CLASS1_PE*N + 7));

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic [27:0] action_mem [0:MAX_ACTIONS-1];
    integer action_count;
    integer fixed_action_index = 0;
    integer adaptive_action_index = 0;
    integer cycle_index = 0;
    string stimulus_path;

    logic fixed_external_valid;
    logic [3:0] fixed_event_source;
    logic [15:0] fixed_teacher_spike;
    logic fixed_maintenance_tick;
    logic fixed_ready;
    logic fixed_overflow;
    logic [15:0] fixed_spikes;
    logic [79:0] fixed_connection_counts;
    logic fixed_evaluation;
    logic [3:0] fixed_pattern_id;
    logic fixed_label;
    logic fixed_ready_sampled;
    logic fixed_accepted;

    logic adaptive_external_valid;
    logic adaptive_learning_enable = 1'b1;
    logic [3:0] adaptive_event_source;
    logic [15:0] adaptive_teacher_spike;
    logic adaptive_maintenance_tick;
    logic adaptive_ready;
    logic adaptive_overflow;
    logic [15:0] adaptive_spikes;
    logic [79:0] adaptive_connection_counts;
    logic adaptive_evaluation;
    logic [3:0] adaptive_pattern_id;
    logic adaptive_label;
    logic adaptive_ready_sampled;
    logic adaptive_accepted;

    always #5 clk = ~clk;

    eap16_fixed_topology_top #(
        .N(N),
        .EVENT_FIFO_DEPTH(64),
        .WEIGHT_W(8),
        .THRESHOLD(TEST_THRESHOLD),
        .FIXED_WEIGHT(FIXED_WEIGHT),
        .TOPOLOGY_MASK(FIXED_TOPOLOGY)
    ) fixed_network (
        .clk(clk),
        .rst(rst),
        .event_valid(fixed_external_valid),
        .event_source(fixed_event_source),
        .teacher_spike(fixed_teacher_spike),
        .maintenance_tick(fixed_maintenance_tick),
        .event_ready(fixed_ready),
        .event_overflow(fixed_overflow),
        .spikes(fixed_spikes),
        .packed_connection_counts(fixed_connection_counts)
    );

    eap16_top #(
        .N(N),
        .FANIN(N),
        .THRESHOLD(TEST_THRESHOLD),
        .WEIGHT_W(8),
        .IDLE_W(8),
        .EVENT_FIFO_DEPTH(64)
    ) adaptive_network (
        .clk(clk),
        .rst(rst),
        .learning_enable(adaptive_learning_enable),
        .event_valid(adaptive_external_valid),
        .event_source(adaptive_event_source),
        .teacher_spike(adaptive_teacher_spike),
        .maintenance_tick(adaptive_maintenance_tick),
        .event_ready(adaptive_ready),
        .event_overflow(adaptive_overflow),
        .spikes(adaptive_spikes),
        .packed_connection_counts(adaptive_connection_counts)
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
        $display("CONFIG,%0d,%h,%0d,%0d", N, FIXED_TOPOLOGY,
                 TEST_THRESHOLD, FIXED_WEIGHT);

        while ((fixed_action_index < action_count ||
                adaptive_action_index < action_count) &&
               cycle_index < MAX_CYCLES) begin
            @(negedge clk);

            if (fixed_action_index < action_count) begin
                fixed_external_valid =
                    action_mem[fixed_action_index][1];
                fixed_event_source =
                    action_mem[fixed_action_index][5:2];
                fixed_teacher_spike =
                    action_mem[fixed_action_index][21:6];
                fixed_maintenance_tick =
                    action_mem[fixed_action_index][0];
                fixed_evaluation =
                    action_mem[fixed_action_index][22];
                fixed_pattern_id =
                    action_mem[fixed_action_index][26:23];
                fixed_label =
                    action_mem[fixed_action_index][27];
            end else begin
                fixed_external_valid = 1'b0;
                fixed_event_source = '0;
                fixed_teacher_spike = '0;
                fixed_maintenance_tick = 1'b0;
                fixed_evaluation = 1'b0;
                fixed_pattern_id = '0;
                fixed_label = 1'b0;
            end

            if (adaptive_action_index < action_count) begin
                adaptive_external_valid =
                    action_mem[adaptive_action_index][1];
                adaptive_learning_enable =
                    !action_mem[adaptive_action_index][22];
                adaptive_event_source =
                    action_mem[adaptive_action_index][5:2];
                adaptive_teacher_spike =
                    action_mem[adaptive_action_index][21:6];
                adaptive_maintenance_tick =
                    action_mem[adaptive_action_index][0];
                adaptive_evaluation =
                    action_mem[adaptive_action_index][22];
                adaptive_pattern_id =
                    action_mem[adaptive_action_index][26:23];
                adaptive_label =
                    action_mem[adaptive_action_index][27];
            end else begin
                adaptive_external_valid = 1'b0;
                adaptive_learning_enable = 1'b1;
                adaptive_event_source = '0;
                adaptive_teacher_spike = '0;
                adaptive_maintenance_tick = 1'b0;
                adaptive_evaluation = 1'b0;
                adaptive_pattern_id = '0;
                adaptive_label = 1'b0;
            end

            #1;
            fixed_ready_sampled = fixed_ready;
            adaptive_ready_sampled = adaptive_ready;
            fixed_accepted = fixed_external_valid && fixed_ready_sampled;
            adaptive_accepted =
                adaptive_external_valid && adaptive_ready_sampled;

            @(posedge clk);
            #1;
            $display(
                "TRACE,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%04h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%04h,%0d,%0d,%0d",
                cycle_index,
                fixed_action_index,
                fixed_evaluation,
                fixed_pattern_id,
                fixed_label,
                fixed_external_valid,
                fixed_event_source,
                fixed_ready_sampled,
                fixed_accepted,
                fixed_spikes,
                fixed_connection_counts[CLASS0_PE*5 +: 5],
                fixed_connection_counts[CLASS1_PE*5 +: 5],
                fixed_overflow,
                adaptive_action_index,
                adaptive_evaluation,
                adaptive_pattern_id,
                adaptive_label,
                adaptive_external_valid,
                adaptive_event_source,
                adaptive_ready_sampled,
                adaptive_accepted,
                adaptive_spikes,
                adaptive_connection_counts[CLASS0_PE*5 +: 5],
                adaptive_connection_counts[CLASS1_PE*5 +: 5],
                adaptive_overflow
            );

            if (fixed_action_index < action_count &&
                (!fixed_external_valid || fixed_ready_sampled))
                fixed_action_index = fixed_action_index + 1;
            if (adaptive_action_index < action_count &&
                (!adaptive_external_valid || adaptive_ready_sampled))
                adaptive_action_index = adaptive_action_index + 1;
            cycle_index = cycle_index + 1;
        end

        if (fixed_action_index != action_count ||
            adaptive_action_index != action_count)
            $fatal(1, "simulation exceeded %0d cycles", MAX_CYCLES);

        $display("END,%0d", cycle_index);
        for (int slot = 0; slot < N; slot++) begin
            if (adaptive_network.gen_pe[CLASS0_PE].u_pe.syn_valid[slot])
                $display("EDGE,%0d,%0d,%0d", CLASS0_PE,
                         adaptive_network.gen_pe[CLASS0_PE].u_pe.syn_source[slot],
                         $signed(adaptive_network.gen_pe[CLASS0_PE].u_pe.syn_weight[slot]));
            if (adaptive_network.gen_pe[CLASS1_PE].u_pe.syn_valid[slot])
                $display("EDGE,%0d,%0d,%0d", CLASS1_PE,
                         adaptive_network.gen_pe[CLASS1_PE].u_pe.syn_source[slot],
                         $signed(adaptive_network.gen_pe[CLASS1_PE].u_pe.syn_weight[slot]));
        end
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "SNN classification comparison timed out");
    end
endmodule
