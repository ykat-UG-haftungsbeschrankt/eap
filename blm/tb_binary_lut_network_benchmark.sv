/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

`timescale 1ns/1ps

module tb_binary_lut_network_benchmark;
    localparam int N = 16;
    localparam int FIFO_DEPTH = 64;
    localparam int ID_W = $clog2(N);
    localparam int EVENT_COUNT = 256;
    localparam int TEACHER_PE = 1;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic learning_enable = 1'b0;
    logic event_valid = 1'b0;
    logic [ID_W-1:0] event_source = '0;
    logic [N-1:0] teacher_spike = '0;
    logic maintenance_tick = 1'b0;
    logic event_ready;
    logic event_overflow;
    logic [N-1:0] spikes;
    logic [N*5-1:0] packed_connection_counts;
    integer cycle_count = 0;

    always #5 clk = ~clk;

    always @(posedge clk)
        cycle_count <= cycle_count + 1;

    binary_lut_array #(
        .N(N),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .learning_enable(learning_enable),
        .event_valid(event_valid),
        .event_source(event_source),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .event_ready(event_ready),
        .event_overflow(event_overflow),
        .spikes(spikes),
        .packed_connection_counts(packed_connection_counts)
    );

    task automatic reset_network(input logic enable_learning);
        begin
            @(negedge clk);
            rst = 1'b1;
            learning_enable = enable_learning;
            event_valid = 1'b0;
            event_source = '0;
            teacher_spike = '0;
            maintenance_tick = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    task automatic send_external_event(
        input logic [ID_W-1:0] source,
        output integer accepted_cycle
    );
        logic accepted;
        integer wait_cycles;
        begin
            @(negedge clk);
            event_valid = 1'b1;
            event_source = source;
            accepted = 1'b0;
            wait_cycles = 0;
            while (!accepted) begin
                @(posedge clk);
                accepted = event_valid && event_ready;
                #1;
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > FIFO_DEPTH + N)
                    $fatal(1, "external event remained backpressured");
            end
            accepted_cycle = cycle_count;
            @(negedge clk);
            event_valid = 1'b0;
        end
    endtask

    task automatic apply_teacher_spike(input integer pe);
        begin
            @(negedge clk);
            teacher_spike = N'(1) << pe;
            @(posedge clk);
            #1;
            teacher_spike = '0;
        end
    endtask

    task automatic apply_maintenance_tick;
        begin
            @(negedge clk);
            maintenance_tick = 1'b1;
            @(posedge clk);
            #1;
            maintenance_tick = 1'b0;
        end
    endtask

    task automatic run_event_throughput;
        integer accepted;
        integer delivered;
        integer stalls;
        integer cycles;
        integer rate_milli;
        logic [ID_W-1:0] expected_source;
        begin
            accepted = 0;
            delivered = 0;
            stalls = 0;
            cycles = 0;

            @(negedge clk);
            event_valid = 1'b1;
            event_source = '0;

            while (delivered < EVENT_COUNT) begin
                @(posedge clk);
                cycles = cycles + 1;

                if (event_valid) begin
                    if (event_ready) begin
                        expected_source = ID_W'(accepted % N);
                        if (event_source !== expected_source)
                            $fatal(1, "external burst source order changed");
                        accepted = accepted + 1;
                    end else begin
                        stalls = stalls + 1;
                    end
                end

                if (dut.routed_event_valid) begin
                    expected_source = ID_W'(delivered % N);
                    if (dut.routed_event_source !== expected_source)
                        $fatal(1, "routed burst source order changed");
                    delivered = delivered + 1;
                end

                @(negedge clk);
                if (accepted < EVENT_COUNT) begin
                    event_valid = 1'b1;
                    event_source = ID_W'(accepted % N);
                end else begin
                    event_valid = 1'b0;
                end
            end

            if (accepted != EVENT_COUNT || delivered != EVENT_COUNT)
                $fatal(1, "event burst lost or duplicated events");
            if (stalls != 0)
                $fatal(1, "uncontended FIFO burst was backpressured");
            if (event_overflow)
                $fatal(1, "event burst caused router overflow");

            rate_milli = (1000 * delivered) / cycles;
            $display(
                "Saturated routing: %0d/%0d delivered in %0d cycles (%0d.%03d broadcasts/cycle), stalls=%0d",
                delivered, EVENT_COUNT, cycles,
                rate_milli / 1000, rate_milli % 1000, stalls
            );
        end
    endtask

    task automatic run_supervised_spike_path;
        integer first_event_cycle;
        integer ignored_cycle;
        integer spike_cycle;
        integer wait_cycles;
        integer feedback_events;
        logic saw_spike;
        begin
            reset_network(1'b1);

            send_external_event(ID_W'(0), first_event_cycle);
            repeat (3) @(posedge clk);
            if (packed_connection_counts[TEACHER_PE*5 +: 5] != 0)
                $fatal(1, "connection formed before teaching spike");

            apply_teacher_spike(TEACHER_PE);
            if (!spikes[TEACHER_PE])
                $fatal(1, "teacher signal did not create its target spike");
            if (packed_connection_counts[TEACHER_PE*5 +: 5] != 5'd1)
                $fatal(1, "teacher did not form source-0 connection");

            apply_maintenance_tick();

            send_external_event(ID_W'(0), ignored_cycle);
            send_external_event(ID_W'(0), ignored_cycle);
            send_external_event(ID_W'(0), ignored_cycle);

            saw_spike = 1'b0;
            spike_cycle = 0;
            for (wait_cycles = 0; wait_cycles < 20 && !saw_spike;
                 wait_cycles = wait_cycles + 1) begin
                @(posedge clk);
                #1;
                if (spikes[TEACHER_PE]) begin
                    saw_spike = 1'b1;
                    spike_cycle = cycle_count;
                end
            end
            if (!saw_spike)
                $fatal(1, "learned edge did not produce a target-PE spike");

            feedback_events = 0;
            for (wait_cycles = 0; wait_cycles < 20 &&
                 feedback_events == 0; wait_cycles = wait_cycles + 1) begin
                @(posedge clk);
                if (dut.routed_event_valid &&
                    dut.routed_event_source == ID_W'(TEACHER_PE))
                    feedback_events = feedback_events + 1;
                #1;
            end
            if (feedback_events != 1)
                $fatal(1, "target spike was not routed back as an event");
            if (event_overflow)
                $fatal(1, "supervised spike path caused event overflow");

            $display(
                "Supervised path: formed 0->PE%0d; 3 source-0 events produced a spike %0d cycles after the first training event; feedback events=%0d",
                TEACHER_PE, spike_cycle - first_event_cycle, feedback_events
            );
        end
    endtask

    initial begin
        reset_network(1'b0);
        run_event_throughput();
        run_supervised_spike_path();
        $display("PASS: 16-PE binary network benchmark assertions");
        $finish;
    end

    initial begin
        #100_000;
        $fatal(1, "binary network benchmark timed out");
    end
endmodule
