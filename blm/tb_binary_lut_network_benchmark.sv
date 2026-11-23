/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

`timescale 1ns/1ps

module tb_binary_lut_network_benchmark;
    localparam int N = 16;
    localparam int ID_W = $clog2(N);
    localparam int EVENT_COUNT = 256;
    localparam int TEACHER_PE = 1;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic learning_enable = 1'b0;
    logic event_valid = 1'b0;
    logic [ID_W-1:0] event_source = '0;
    logic [ID_W-1:0] event_target_pe = ID_W'(TEACHER_PE);
    logic event_broadcast = 1'b1;
    logic [N-1:0] teacher_spike = '0;
    logic maintenance_tick = 1'b0;
    logic event_ready;
    logic [N-1:0] spikes;
    logic [N*N-1:0] synapse_map;
    logic [N*5-1:0] packed_connection_counts;
    integer cycle_count = 0;

    always #5 clk = ~clk;

    always @(posedge clk)
        cycle_count <= cycle_count + 1;

    binary_lut_array #(
        .N(N)
    ) dut (
        .clk(clk),
        .rst(rst),
        .learning_enable(learning_enable),
        .event_valid(event_valid),
        .event_source(event_source),
        .event_target_pe(event_target_pe),
        .event_broadcast(event_broadcast),
        .selected_pe(ID_W'(TEACHER_PE)),
        .synapse_map(synapse_map),
        .snapshot_pause(1'b0),
        .snapshot_addr('0),
        .snapshot_write_enable(1'b0),
        .snapshot_write_data(32'b0),
        .snapshot_read_data(),
        .snapshot_write_ready(),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .event_ready(event_ready),
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
            event_target_pe = ID_W'(TEACHER_PE);
            event_broadcast = 1'b1;
            teacher_spike = '0;
            maintenance_tick = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    task automatic send_event(input logic [ID_W-1:0] source);
        logic accepted;
        integer waits;
        begin
            @(negedge clk);
            event_valid = 1'b1;
            event_source = source;
            accepted = 1'b0;
            waits = 0;
            while (!accepted) begin
                @(posedge clk);
                accepted = event_ready;
                #1;
                waits = waits + 1;
                if (waits > 2)
                    $fatal(1, "addressed event was unexpectedly backpressured");
            end
            @(negedge clk);
            event_valid = 1'b0;
        end
    endtask

    task automatic teach_pe(input int pe_id);
        begin
            @(negedge clk);
            teacher_spike[pe_id] = 1'b1;
            @(posedge clk);
            #1;
            teacher_spike[pe_id] = 1'b0;
        end
    endtask

    task automatic run_parallel_pe_throughput;
        integer accepted;
        integer stalls;
        integer cycles;
        integer total_pe_events;
        begin
            reset_network(1'b0);
            event_broadcast = 1'b1;
            accepted = 0;
            stalls = 0;
            cycles = 0;

            @(negedge clk);
            event_valid = 1'b1;
            event_source = '0;
            while (accepted < EVENT_COUNT) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (event_ready) begin
                    if (event_source !== ID_W'(accepted % N))
                        $fatal(1, "broadcast source order changed");
                    accepted = accepted + 1;
                end else begin
                    stalls = stalls + 1;
                end

                #1;
                @(negedge clk);
                if (accepted < EVENT_COUNT) begin
                    event_valid = 1'b1;
                    event_source = ID_W'(accepted % N);
                end else begin
                    event_valid = 1'b0;
                end
            end

            if (accepted != EVENT_COUNT || stalls != 0)
                $fatal(1, "broadcast stream lost or stalled events");

            total_pe_events = N*accepted;
            $display(
                "Broadcast event stream: %0d PE-events in %0d cycles (%0d PE-events/cycle)",
                total_pe_events, cycles, total_pe_events/cycles
            );
        end
    endtask

    task automatic run_supervised_pe_path;
        integer first_event_cycle;
        integer spike_cycle;
        logic saw_spike;
        begin
            reset_network(1'b1);
            event_broadcast = 1'b0;
            event_target_pe = ID_W'(TEACHER_PE);
            send_event(ID_W'(0));
            first_event_cycle = cycle_count;
            if (dut.gen_pe[TEACHER_PE].u_pe.candidate_pre[0] !== 1'b1)
                $fatal(1, "addressed PE did not record source 0");
            if (dut.gen_pe[0].u_pe.candidate_pre[0] !== 1'b0)
                $fatal(1, "source event leaked to a different PE");
            if (packed_connection_counts[TEACHER_PE*5 +: 5] != 0)
                $fatal(1, "connection formed before teaching spike");

            teach_pe(TEACHER_PE);
            if (!spikes[TEACHER_PE])
                $fatal(1, "teacher signal did not create its target spike");
            if (packed_connection_counts[TEACHER_PE*5 +: 5] != 5'd1)
                $fatal(1, "teacher did not form source-0 connection");
            if (synapse_map[TEACHER_PE*N] !== 1'b1)
                $fatal(1, "teacher formed a connection on the wrong PE");

            @(negedge clk);
            maintenance_tick = 1'b1;
            @(posedge clk);
            #1;
            maintenance_tick = 1'b0;
            if (dut.gen_pe[0].u_pe.candidate_pre[TEACHER_PE] !== 1'b1)
                $fatal(1, "teacher spike was not broadcast as a PE event");

            saw_spike = 1'b0;
            spike_cycle = 0;
            for (int event_index = 0; event_index < 3; event_index++) begin
                send_event(ID_W'(0));
                if (spikes[TEACHER_PE]) begin
                    saw_spike = 1'b1;
                    spike_cycle = cycle_count;
                end
            end
            if (!saw_spike)
                $fatal(1, "learned edge did not produce a target-PE spike");

            $display(
                "Addressed learning: source 0 formed on PE %0d; spike after %0d cycles; peer spike broadcast verified",
                TEACHER_PE, spike_cycle - first_event_cycle
            );
        end
    endtask

    initial begin
        reset_network(1'b0);
        run_parallel_pe_throughput();
        run_supervised_pe_path();
        $display("PASS: PE-addressable binary network checks");
        $finish;
    end

    initial begin
        #100_000;
        $fatal(1, "binary network benchmark timed out");
    end
endmodule
