/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

`timescale 1ns/1ps

module tb_eap_parameter_boundaries;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic event_valid = 1'b0;
    logic [0:0] event_source = 1'b0;
    logic teacher_spike = 1'b0;
    logic maintenance_tick = 1'b0;
    logic spike;
    logic [0:0] connection_count;
    logic default_weight_spike;
    logic [0:0] default_weight_connection_count;
    logic fixed_weight_spike;
    logic [1:0] fixed_weight_connection_count;

    always #5 clk = ~clk;

    for (genvar width = 2; width <= 8; width++) begin : gen_weight_defaults
        eap16_weight_default_check #(
            .WEIGHT_W(width)
        ) check (
            .clk(clk),
            .rst(rst)
        );
    end

    eap_dynamic_pe #(
        .PE_ID(0),
        .N(2),
        .FANIN(1),
        .WEIGHT_W(4),
        .IDLE_W(4),
        .INITIAL_WEIGHT(4'sd4),
        .MIN_WEIGHT(4'sd2),
        .FORM_THRESHOLD(8'd1),
        .PRUNE_AGE(4'd2)
    ) dut (
        .clk(clk),
        .rst(rst),
        .learning_enable(1'b1),
        .event_valid(event_valid),
        .event_source(event_source),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .spike(spike),
        .connection_count(connection_count)
    );

    eap_dynamic_pe #(
        .PE_ID(0),
        .N(2),
        .FANIN(1),
        .WEIGHT_W(4),
        .IDLE_W(4),
        .MIN_WEIGHT(4'sd2),
        .FORM_THRESHOLD(8'd1),
        .PRUNE_AGE(4'd2)
    ) default_weight_pe (
        .clk(clk),
        .rst(rst),
        .learning_enable(1'b1),
        .event_valid(event_valid),
        .event_source(event_source),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .spike(default_weight_spike),
        .connection_count(default_weight_connection_count)
    );

    eap16_fixed_topology_pe #(
        .PE_ID(1),
        .N(2),
        .WEIGHT_W(4),
        .THRESHOLD(24'sd100),
        .SOURCE_MASK(2'b01)
    ) fixed_weight_pe (
        .clk(clk),
        .rst(rst),
        .event_valid(event_valid),
        .event_source(event_source),
        .teacher_spike(teacher_spike),
        .spike(fixed_weight_spike),
        .connection_count(fixed_weight_connection_count)
    );

    eap16_fixed_topology_top #(
        .N(2),
        .EVENT_FIFO_DEPTH(4),
        .WEIGHT_W(4),
        .THRESHOLD(24'sd100),
        .TOPOLOGY_MASK(4'b0100)
    ) fixed_weight_top (
        .clk(clk),
        .rst(rst),
        .event_valid(1'b0),
        .event_source(1'b0),
        .teacher_spike(2'b00),
        .maintenance_tick(1'b0),
        .event_ready(),
        .event_overflow(),
        .spikes(),
        .packed_connection_counts()
    );

    task automatic drive_cycle(
        input logic valid,
        input logic source,
        input logic teacher,
        input logic maintenance
    );
        begin
            @(negedge clk);
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
        if (connection_count !== 1'b0)
            $fatal(1, "N=2/FANIN=1 reset boundary failed");
        if (default_weight_pe.INITIAL_WEIGHT !== 4'sd1 ||
            fixed_weight_pe.FIXED_WEIGHT !== 4'sd1 ||
            fixed_weight_top.FIXED_WEIGHT !== 4'sd1 ||
            fixed_weight_connection_count !== 2'd1)
            $fatal(1, "4-bit default weights are not width-scaled");

        @(negedge clk);
        rst = 1'b0;

        drive_cycle(1'b1, 1'b0, 1'b0, 1'b0);
        if (fixed_weight_pe.membrane !== 24'sd1)
            $fatal(1, "4-bit fixed weight did not sign-extend as +1");
        drive_cycle(1'b0, 1'b0, 1'b1, 1'b0);
        drive_cycle(1'b0, 1'b0, 1'b0, 1'b0);
        if (dut.candidate_pre[0] !== 8'd0 || connection_count !== 1'b0)
            $fatal(1, "N=2 boundary did not exclude PE_ID zero as a source");

        drive_cycle(1'b1, 1'b1, 1'b0, 1'b0);
        drive_cycle(1'b0, 1'b0, 1'b1, 1'b0);
        if (dut.pending[1] !== 1'b1)
            $fatal(1, "N=2 boundary did not queue source ID one");
        drive_cycle(1'b0, 1'b0, 1'b0, 1'b0);
        if (connection_count !== 1'b1 || dut.syn_source[0] !== 1'b1)
            $fatal(1, "FANIN=1 boundary did not allocate its sole slot");
        if (default_weight_pe.syn_weight[0] !== 4'sd1)
            $fatal(1, "4-bit dynamic default did not initialize to +1");
        if (dut.syn_weight[0] !== 4'sd4)
            $fatal(1, "configured 4-bit initial weight was not preserved");

        repeat (4) drive_cycle(1'b0, 1'b0, 1'b1, 1'b0);
        if (dut.syn_weight[0] !== 4'sd7)
            $fatal(1, "4-bit weight did not saturate at +7");

        drive_cycle(1'b1, 1'b1, 1'b0, 1'b0);
        if (dut.syn_weight[0] !== 4'sd6)
            $fatal(1, "configured weight width did not support depression");

        @(negedge clk);
        dut.syn_weight[0] = 4'sd1;
        repeat (3) drive_cycle(1'b0, 1'b0, 1'b0, 1'b1);
        if (connection_count !== 1'b0)
            $fatal(1, "configured 4-bit idle age did not prune at its threshold");

        $display("PASS: minimum PE parameters and 4-bit weight/idle-age configuration");
        $finish;
    end
endmodule

module eap16_weight_default_check #(
    parameter int WEIGHT_W = 8
) (
    input logic clk,
    input logic rst
);
    localparam logic signed [WEIGHT_W-1:0] EXPECTED_WEIGHT =
        (WEIGHT_W >= 8) ? WEIGHT_W'(8) :
        (WEIGHT_W >= 7) ? WEIGHT_W'(4) :
        (WEIGHT_W >= 6) ? WEIGHT_W'(2) : WEIGHT_W'(1);

    logic adaptive_spike;
    logic [$clog2(2)-1:0] adaptive_connection_count;
    logic fixed_spike;
    logic [$clog2(3)-1:0] fixed_connection_count;

    eap_dynamic_pe #(
        .N(2),
        .FANIN(1),
        .WEIGHT_W(WEIGHT_W)
    ) adaptive_pe (
        .clk(clk),
        .rst(rst),
        .learning_enable(1'b1),
        .event_valid(1'b0),
        .event_source(1'b0),
        .teacher_spike(1'b0),
        .maintenance_tick(1'b0),
        .spike(adaptive_spike),
        .connection_count(adaptive_connection_count)
    );

    eap16_fixed_topology_pe #(
        .N(2),
        .WEIGHT_W(WEIGHT_W),
        .SOURCE_MASK(2'b00)
    ) fixed_pe (
        .clk(clk),
        .rst(rst),
        .event_valid(1'b0),
        .event_source(1'b0),
        .teacher_spike(1'b0),
        .spike(fixed_spike),
        .connection_count(fixed_connection_count)
    );

    initial begin
        #1;
        if (adaptive_pe.INITIAL_WEIGHT !== EXPECTED_WEIGHT ||
            fixed_pe.FIXED_WEIGHT !== EXPECTED_WEIGHT)
            $fatal(1, "incorrect default weight for WEIGHT_W=%0d",
                   WEIGHT_W);
        $display("PASS: width-scaled weight defaults at WEIGHT_W=%0d",
                 WEIGHT_W);
    end
endmodule
