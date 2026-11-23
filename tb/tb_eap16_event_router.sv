/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

`timescale 1ns/1ps

module tb_eap16_event_router;
    localparam int N = 4;

    logic clk = 1'b0;
    logic router_rst = 1'b1;
    logic external_valid = 1'b0;
    logic [1:0] external_source = '0;
    logic external_ready;
    logic [N-1:0] feedback_spikes = '0;
    logic event_valid;
    logic [1:0] event_source;
    logic event_consume = 1'b0;
    logic overflow;
    logic [2:0] level;

    logic min_rst = 1'b1;
    logic min_external_valid = 1'b0;
    logic min_external_source = 1'b0;
    logic min_external_ready;
    logic [1:0] min_feedback_spikes = '0;
    logic min_event_valid;
    logic min_event_source;
    logic min_event_consume = 1'b0;
    logic min_overflow;
    logic [1:0] min_level;

    logic top_rst = 1'b1;
    logic top_event_valid = 1'b0;
    logic top_event_source = 1'b0;
    logic top_event_ready;
    logic [1:0] top_teacher_spike = '0;
    logic top_maintenance_tick = 1'b0;
    logic [1:0] top_spikes;
    logic top_overflow;
    logic [9:0] top_connection_counts;

    always #5 clk = ~clk;

    eap16_event_router #(
        .N(N),
        .FIFO_DEPTH(4)
    ) dut (
        .clk(clk),
        .rst(router_rst),
        .external_valid(external_valid),
        .external_source(external_source),
        .external_ready(external_ready),
        .feedback_spikes(feedback_spikes),
        .event_valid(event_valid),
        .event_source(event_source),
        .event_consume(event_consume),
        .overflow(overflow),
        .level(level),
        .snapshot_pause(1'b0),
        .snapshot_addr('0),
        .snapshot_write_enable(1'b0),
        .snapshot_write_data(32'b0),
        .snapshot_read_data()
    );

    eap16_event_router #(
        .N(2),
        .FIFO_DEPTH(2)
    ) min_depth_router (
        .clk(clk),
        .rst(min_rst),
        .external_valid(min_external_valid),
        .external_source(min_external_source),
        .external_ready(min_external_ready),
        .feedback_spikes(min_feedback_spikes),
        .event_valid(min_event_valid),
        .event_source(min_event_source),
        .event_consume(min_event_consume),
        .overflow(min_overflow),
        .level(min_level),
        .snapshot_pause(1'b0),
        .snapshot_addr('0),
        .snapshot_write_enable(1'b0),
        .snapshot_write_data(32'b0),
        .snapshot_read_data()
    );

    eap16_top #(
        .N(2),
        .FANIN(1),
        .EVENT_FIFO_DEPTH(4)
    ) network (
        .clk(clk),
        .rst(top_rst),
        .learning_enable(1'b1),
        .event_valid(top_event_valid),
        .event_source(top_event_source),
        .teacher_spike(top_teacher_spike),
        .maintenance_tick(top_maintenance_tick),
        .event_ready(top_event_ready),
        .event_overflow(top_overflow),
        .spikes(top_spikes),
        .packed_connection_counts(top_connection_counts)
    );

    task automatic push_external(input logic [1:0] source);
        begin
            @(negedge clk);
            external_valid = 1'b1;
            external_source = source;
            event_consume = 1'b0;
            feedback_spikes = '0;
            #1;
            if (!external_ready)
                $fatal(1, "external event was not accepted when FIFO had room");
            @(posedge clk);
            #1;
            external_valid = 1'b0;
        end
    endtask

    task automatic pop_expected(input logic [1:0] expected);
        begin
            @(negedge clk);
            external_valid = 1'b0;
            feedback_spikes = '0;
            event_consume = 1'b0;
            #1;
            if (!event_valid || event_source !== expected)
                $fatal(1, "FIFO order mismatch: expected %0d, got %0d",
                       expected, event_source);
            event_consume = 1'b1;
            @(posedge clk);
            #1;
            event_consume = 1'b0;
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        #1;
        if (event_valid || level != 0 || overflow)
            $fatal(1, "router reset did not clear FIFO state");

        @(negedge clk);
        router_rst = 1'b0;
        push_external(2'd2);

        @(negedge clk);
        external_valid = 1'b1;
        external_source = 2'd0;
        feedback_spikes = 4'b1010;
        #1;
        if (!external_ready)
            $fatal(1, "arbiter did not accept simultaneous external input");
        @(posedge clk);
        #1;
        external_valid = 1'b0;
        feedback_spikes = '0;

        @(negedge clk);
        external_valid = 1'b1;
        external_source = 2'd2;
        #1;
        if (external_ready)
            $fatal(1, "arbiter did not grant pending feedback before host input");
        @(posedge clk);
        #1;
        if (level != 3'd3 || dut.pending_spikes[1] != 0 ||
            dut.pending_spikes[3] != 1)
            $fatal(1, "first pending feedback request was not granted");

        @(negedge clk);
        #1;
        if (external_ready)
            $fatal(1, "arbiter did not continue round-robin feedback service");
        @(posedge clk);
        #1;
        if (level != 3'd4 || overflow || dut.pending_spikes[3] != 0)
            $fatal(1, "second simultaneous spike ID was not queued");

        @(negedge clk);
        #1;
        if (external_ready)
            $fatal(1, "external input was not backpressured at FIFO full");
        @(posedge clk);
        #1;
        if (level != 3'd4)
            $fatal(1, "backpressured event changed the full FIFO");

        @(negedge clk);
        event_consume = 1'b1;
        #1;
        if (!external_ready || event_source !== 2'd2)
            $fatal(1, "simultaneous dequeue/enqueue did not free a FIFO slot");
        @(posedge clk);
        #1;
        external_valid = 1'b0;
        event_consume = 1'b0;
        if (level != 3'd4 || event_source !== 2'd0)
            $fatal(1, "full FIFO simultaneous dequeue/enqueue failed");

        pop_expected(2'd0);
        pop_expected(2'd1);
        pop_expected(2'd3);
        pop_expected(2'd2);
        if (event_valid || level != 0)
            $fatal(1, "FIFO did not drain completely");
        $display("PASS: shared FIFO ordering, arbitration, and external backpressure");

        push_external(2'd0);
        push_external(2'd1);
        push_external(2'd2);
        push_external(2'd3);
        repeat (5) begin
            @(negedge clk);
            feedback_spikes = 4'b0100;
            @(posedge clk);
            #1;
            feedback_spikes = '0;
        end
        if (!overflow || level != 3'd4 ||
            dut.pending_spikes[2] != 3'd4)
            $fatal(1, "feedback counter saturation was not reported and retained");
        $display("PASS: bounded feedback queue overflow is explicit");

        @(negedge clk);
        router_rst = 1'b1;
        external_valid = 1'b0;
        feedback_spikes = '0;
        repeat (2) @(posedge clk);
        #1;
        if (overflow || level != 0 || event_valid)
            $fatal(1, "router reset did not clear overflow and queued events");
        @(negedge clk);
        router_rst = 1'b0;

        top_teacher_spike = 2'b01;
        top_rst = 1'b0;
        @(posedge clk);
        #1;
        if (top_spikes !== 2'b01)
            $fatal(1, "teacher-generated spike was not exposed");
        @(negedge clk);
        top_teacher_spike = '0;
        repeat (3) @(posedge clk);
        #1;
        if (network.gen_pe[1].u_pe.candidate_pre[0] !== 8'd1 ||
            network.gen_pe[0].u_pe.candidate_pre[0] !== 8'd0)
            $fatal(1, "spike feedback did not route source ID zero to other PEs");
        if (top_overflow)
            $fatal(1, "unexpected overflow in closed-loop top-level test");
        $display("PASS: top-level spike feedback and source ID zero");
        $display("All event router tests passed.");
        $finish;
    end

    initial begin
        #100_000;
        $fatal(1, "event router test timed out");
    end

    initial begin
        repeat (2) @(posedge clk);
        #1;
        if (min_level != 0 || min_event_valid || min_overflow)
            $fatal(1, "minimum-depth FIFO reset failed");

        @(negedge clk);
        min_rst = 1'b0;
        @(negedge clk);
        min_external_valid = 1'b1;
        min_external_source = 1'b0;
        #1;
        if (!min_external_ready)
            $fatal(1, "minimum-depth FIFO rejected its first event");
        @(posedge clk);
        #1;

        @(negedge clk);
        min_external_source = 1'b1;
        #1;
        if (!min_external_ready)
            $fatal(1, "minimum-depth FIFO rejected its second event");
        @(posedge clk);
        #1;
        min_external_valid = 1'b0;
        if (min_level != 2 || min_event_source !== 1'b0)
            $fatal(1, "minimum-depth FIFO did not fill in order");

        @(negedge clk);
        min_external_valid = 1'b1;
        min_external_source = 1'b0;
        min_event_consume = 1'b1;
        #1;
        if (!min_external_ready || min_event_source !== 1'b0)
            $fatal(1, "minimum-depth FIFO failed simultaneous pop/push");
        @(posedge clk);
        #1;
        min_external_valid = 1'b0;
        min_event_consume = 1'b0;
        if (min_level != 2 || min_event_source !== 1'b1)
            $fatal(1, "minimum-depth FIFO pointer did not wrap correctly");

        @(negedge clk);
        min_event_consume = 1'b1;
        #1;
        if (min_event_source !== 1'b1)
            $fatal(1, "minimum-depth FIFO lost the second event");
        @(posedge clk);
        #1;
        min_event_consume = 1'b0;
        if (min_level != 1 || min_event_source !== 1'b0)
            $fatal(1, "minimum-depth FIFO lost the replacement event");

        @(negedge clk);
        min_event_consume = 1'b1;
        @(posedge clk);
        #1;
        min_event_consume = 1'b0;
        if (min_level != 0 || min_event_valid)
            $fatal(1, "minimum-depth FIFO failed to drain");
        $display("PASS: minimum FIFO depth, ID zero, and pointer wraparound");
    end
endmodule
