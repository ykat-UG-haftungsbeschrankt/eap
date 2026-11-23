/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

`timescale 1ns/1ps

module tb_binary_lut_dual_array #(
    parameter int NETWORK_COUNT = 2
);
    localparam int N = 16;
    localparam int FIFO_DEPTH = 64;
    localparam int ID_W = $clog2(N);
    localparam int ADDR_W = $clog2(NETWORK_COUNT*N*N);
    localparam int LEVEL_W = $clog2(FIFO_DEPTH + 1);
    localparam int PENDING_W = LEVEL_W;
    localparam int PTR_W = $clog2(FIFO_DEPTH);
    localparam int ARBITER_W = $clog2(N + 1);
    localparam int CONTROL_BITS =
        LEVEL_W + 2*PTR_W + ARBITER_W + 1;
    localparam int CONTROL_WORDS = (CONTROL_BITS + 31) / 32;
    localparam int PE_STATE_WORDS = 2*N;
    localparam int ARRAY_STATE_WORDS =
        PE_STATE_WORDS + FIFO_DEPTH + N + CONTROL_WORDS;
    localparam int SNAPSHOT_WORDS = NETWORK_COUNT*ARRAY_STATE_WORDS;
    localparam int SNAPSHOT_ADDR_W = $clog2(SNAPSHOT_WORDS);
    localparam int EVENT_COUNT = 256;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic [NETWORK_COUNT-1:0] learning_enable = '0;
    logic snapshot_pause = 1'b0;
    logic [SNAPSHOT_ADDR_W-1:0] snapshot_state_addr = '0;
    logic snapshot_write_enable = 1'b0;
    logic [31:0] snapshot_write_data = '0;
    logic [31:0] snapshot_read_data;
    logic snapshot_write_ready;
    logic [31:0] saved_snapshot [0:SNAPSHOT_WORDS-1];
    logic [NETWORK_COUNT-1:0] event_valid = '0;
    logic [NETWORK_COUNT*ID_W-1:0] event_source = '0;
    logic [NETWORK_COUNT*ID_W-1:0] selected_pe = '0;
    logic [ADDR_W-1:0] synapse_read_addr = '0;
    logic synapse_read_data;
    logic [NETWORK_COUNT*N-1:0] teacher_spike = '0;
    logic [NETWORK_COUNT-1:0] maintenance_tick = '0;
    logic [NETWORK_COUNT-1:0] event_ready;
    logic [NETWORK_COUNT-1:0] event_overflow;
    logic [NETWORK_COUNT*N-1:0] spikes;
    logic [NETWORK_COUNT*5-1:0] selected_connection_counts;
    logic monitor_routes = 1'b0;
    integer route_delivered [0:NETWORK_COUNT-1];

    always #5 clk = ~clk;

    function automatic integer target_pe(input integer network_id);
        target_pe = (network_id % (N - 1)) + 1;
    endfunction

    binary_lut_dual_array #(
        .N(N),
        .FIFO_DEPTH(FIFO_DEPTH),
        .NETWORK_COUNT(NETWORK_COUNT),
        .SYNAPSE_READ_PORT(1'b1)
    ) dut (
        .clk(clk),
        .rst(rst),
        .snapshot_pause(snapshot_pause),
        .snapshot_state_addr(snapshot_state_addr),
        .snapshot_write_enable(snapshot_write_enable),
        .snapshot_write_data(snapshot_write_data),
        .snapshot_read_data(snapshot_read_data),
        .snapshot_write_ready(snapshot_write_ready),
        .learning_enable(learning_enable),
        .event_valid(event_valid),
        .event_source(event_source),
        .selected_pe(selected_pe),
        .synapse_read_addr(synapse_read_addr),
        .synapse_read_data(synapse_read_data),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .event_ready(event_ready),
        .event_overflow(event_overflow),
        .spikes(spikes),
        .selected_connection_counts(selected_connection_counts)
    );

    for (genvar network_id = 0;
         network_id < NETWORK_COUNT;
         network_id++) begin : gen_route_monitor
        always @(posedge clk) begin
            if (monitor_routes &&
                dut.gen_network[network_id].u_array.routed_event_valid) begin
                if (dut.gen_network[network_id].u_array.routed_event_source !==
                    ID_W'((network_id + route_delivered[network_id]) % N))
                    $fatal(1, "network %0d routed source order changed",
                           network_id);
                route_delivered[network_id] =
                    route_delivered[network_id] + 1;
            end
        end
    end

    task automatic reset_network(input logic [NETWORK_COUNT-1:0] learning);
        begin
            @(negedge clk);
            rst = 1'b1;
            learning_enable = learning;
            event_valid = '0;
            event_source = '0;
            teacher_spike = '0;
            maintenance_tick = '0;
            monitor_routes = 1'b0;
            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++) begin
                selected_pe[network_id*ID_W +: ID_W] =
                    ID_W'(target_pe(network_id));
                route_delivered[network_id] = 0;
            end
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    task automatic send_event(
        input int network_id,
        input logic [ID_W-1:0] source
    );
        logic accepted;
        integer waits;
        begin
            @(negedge clk);
            event_source[network_id*ID_W +: ID_W] = source;
            event_valid[network_id] = 1'b1;
            accepted = 1'b0;
            waits = 0;
            while (!accepted) begin
                @(posedge clk);
                accepted = event_ready[network_id];
                #1;
                waits = waits + 1;
                if (waits > FIFO_DEPTH + N)
                    $fatal(1, "network %0d input stayed backpressured",
                           network_id);
            end
            @(negedge clk);
            event_valid[network_id] = 1'b0;
        end
    endtask

    task automatic teach_neuron(input int network_id, input int pe_id);
        begin
            @(negedge clk);
            teacher_spike[network_id*N + pe_id] = 1'b1;
            @(posedge clk);
            #1;
            teacher_spike[network_id*N + pe_id] = 1'b0;
        end
    endtask

    task automatic check_synapse(
        input logic [ADDR_W-1:0] address,
        input logic expected
    );
        begin
            @(negedge clk);
            synapse_read_addr = address;
            #1;
            if (synapse_read_data !== expected)
                $fatal(1, "synapse read at address %0d was %b, expected %b",
                       address, synapse_read_data, expected);
        end
    endtask

    task automatic read_snapshot;
        begin
            for (int word_index = 0;
                 word_index < SNAPSHOT_WORDS;
                 word_index++) begin
                @(negedge clk);
                snapshot_state_addr = SNAPSHOT_ADDR_W'(word_index);
                #1;
                saved_snapshot[word_index] = snapshot_read_data;
            end
        end
    endtask

    task automatic restore_snapshot;
        begin
            for (int word_index = 0;
                 word_index < SNAPSHOT_WORDS;
                 word_index++) begin
                @(negedge clk);
                snapshot_state_addr = SNAPSHOT_ADDR_W'(word_index);
                snapshot_write_data = saved_snapshot[word_index];
                snapshot_write_enable = 1'b1;
                #1;
                if (!snapshot_write_ready)
                    $fatal(1, "snapshot restore was not ready at word %0d",
                           word_index);
                @(posedge clk);
                #1;
            end
            @(negedge clk);
            snapshot_write_enable = 1'b0;
        end
    endtask

    task automatic verify_snapshot;
        begin
            for (int word_index = 0;
                 word_index < SNAPSHOT_WORDS;
                 word_index++) begin
                @(negedge clk);
                snapshot_state_addr = SNAPSHOT_ADDR_W'(word_index);
                #1;
                if (snapshot_read_data !== saved_snapshot[word_index])
                    $fatal(1, "snapshot mismatch at word %0d", word_index);
            end
            if ((32'd1 << SNAPSHOT_ADDR_W) > SNAPSHOT_WORDS) begin
                @(negedge clk);
                snapshot_state_addr = SNAPSHOT_ADDR_W'(SNAPSHOT_WORDS);
                #1;
                if (snapshot_read_data !== 32'b0 || snapshot_write_ready)
                    $fatal(1, "invalid snapshot address did not return zero/not-ready");
            end
        end
    endtask

    task automatic check_exact_snapshot_restore;
        logic accepted;
        integer waits;
        integer fifo_state_base;
        integer pending_state_base;
        integer control_state_base;
        begin
            reset_network({NETWORK_COUNT{1'b1}});
            send_event(0, ID_W'(0));
            repeat (3) @(posedge clk);
            teach_neuron(0, target_pe(0));
            if (selected_connection_counts[0 +: 5] != 5'd1)
                $fatal(1, "snapshot setup failed to learn source 0");

            // Leave both a FIFO entry and a pending feedback spike in flight.
            @(negedge clk);
            event_valid[0] = 1'b1;
            event_source[0 +: ID_W] = ID_W'(3);
            @(posedge clk);
            if (!event_ready[0])
                $fatal(1, "snapshot setup event was not accepted");
            #1;
            @(negedge clk);
            event_valid[0] = 1'b0;
            snapshot_pause = 1'b1;
            if (NETWORK_COUNT > 1) begin
                event_valid[1] = 1'b1;
                event_source[ID_W +: ID_W] = ID_W'(5);
            end
            @(posedge clk);
            #1;
            if (event_ready !== '0)
                $fatal(1, "pause did not backpressure external streams");

            fifo_state_base = PE_STATE_WORDS;
            pending_state_base = PE_STATE_WORDS + FIFO_DEPTH;
            control_state_base = pending_state_base + N;
            read_snapshot();
            if (saved_snapshot[target_pe(0)*2][15:0] !== 16'h0001)
                $fatal(1, "snapshot missed a learned synapse");
            if (saved_snapshot[fifo_state_base + 1][ID_W-1:0] !==
                ID_W'(3))
                $fatal(1, "snapshot missed the queued source-3 event");
            if (saved_snapshot[pending_state_base + 1][PENDING_W-1:0] !==
                PENDING_W'(1))
                $fatal(1, "snapshot missed the pending PE-1 feedback spike");
            if (saved_snapshot[control_state_base][0] !== 1'b1)
                $fatal(1, "snapshot missed the router FIFO count");
            if (saved_snapshot[target_pe(0)*2 + 1][31:4] !== 28'b0 ||
                saved_snapshot[fifo_state_base + 1][31:ID_W] !==
                    (32-ID_W)'(0) ||
                saved_snapshot[pending_state_base + 1][31:PENDING_W] !==
                    (32-PENDING_W)'(0))
                $fatal(1, "snapshot padding bits were not zero");

            // Corrupt saved synapse state, then restore the complete snapshot.
            @(negedge clk);
            snapshot_state_addr =
                SNAPSHOT_ADDR_W'(target_pe(0)*2);
            snapshot_write_data =
                saved_snapshot[target_pe(0)*2] ^ 32'b1;
            snapshot_write_enable = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            snapshot_write_enable = 1'b0;
            snapshot_state_addr =
                SNAPSHOT_ADDR_W'(target_pe(0)*2);
            #1;
            if (snapshot_read_data[0] !== 1'b0)
                $fatal(1, "snapshot test did not corrupt the target bit");

            restore_snapshot();
            verify_snapshot();

            // This offered event is outside the snapshot; hold it stable until
            // the restored network leaves pause and accepts it.
            @(negedge clk);
            snapshot_pause = 1'b0;
            accepted = 1'b0;
            waits = 0;
            while (!accepted) begin
                @(posedge clk);
                accepted = event_ready[1];
                #1;
                waits = waits + 1;
                if (waits > FIFO_DEPTH + N)
                    $fatal(1, "restored network did not resume input");
            end
            @(negedge clk);
            event_valid[1] = 1'b0;
            repeat (8) @(posedge clk);
            if (event_overflow != '0)
                $fatal(1, "snapshot restore caused router overflow");

            $display(
                "Exact snapshot: saved/restored %0d 32-bit words across %0d networks, including FIFO and pending feedback",
                SNAPSHOT_WORDS, NETWORK_COUNT
            );
        end
    endtask

    task automatic check_two_stream_throughput;
        integer accepted [0:NETWORK_COUNT-1];
        integer stalls [0:NETWORK_COUNT-1];
        integer cycles;
        integer completed_count;
        integer aggregate_events;
        logic [ID_W-1:0] expected_source;
        begin
            cycles = 0;
            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++) begin
                accepted[network_id] = 0;
                stalls[network_id] = 0;
                route_delivered[network_id] = 0;
            end

            @(negedge clk);
            event_valid = '1;
            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++)
                event_source[network_id*ID_W +: ID_W] = ID_W'(network_id % N);
            monitor_routes = 1'b1;

            completed_count = 0;
            while (completed_count < NETWORK_COUNT) begin
                @(posedge clk);
                cycles = cycles + 1;

                for (int network_id = 0;
                     network_id < NETWORK_COUNT;
                     network_id++) begin
                    if (event_valid[network_id]) begin
                        if (event_ready[network_id]) begin
                            expected_source =
                                ID_W'((network_id + accepted[network_id]) % N);
                            if (event_source[network_id*ID_W +: ID_W] !==
                                expected_source)
                                $fatal(1, "network %0d input order changed",
                                       network_id);
                            accepted[network_id] =
                                accepted[network_id] + 1;
                        end else begin
                            stalls[network_id] = stalls[network_id] + 1;
                        end
                    end
                end

                #1;
                @(negedge clk);
                completed_count = 0;
                for (int network_id = 0;
                     network_id < NETWORK_COUNT;
                     network_id++) begin
                    if (accepted[network_id] < EVENT_COUNT) begin
                        event_valid[network_id] = 1'b1;
                        event_source[network_id*ID_W +: ID_W] =
                            ID_W'((network_id + accepted[network_id]) % N);
                    end else begin
                        event_valid[network_id] = 1'b0;
                    end

                    if (route_delivered[network_id] == EVENT_COUNT)
                        completed_count = completed_count + 1;
                end
            end
            monitor_routes = 1'b0;

            aggregate_events = NETWORK_COUNT * EVENT_COUNT;
            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++) begin
                if (accepted[network_id] != EVENT_COUNT ||
                    route_delivered[network_id] != EVENT_COUNT)
                    $fatal(1, "network %0d lost or duplicated events",
                           network_id);
                if (stalls[network_id] != 0)
                    $fatal(1, "network %0d unexpectedly stalled",
                           network_id);
                if (event_overflow[network_id])
                    $fatal(1, "network %0d overflowed", network_id);
            end

            $display(
                "%0d parallel streams: each delivered %0d/%0d events in %0d cycles; aggregate %.3f broadcasts/cycle",
                NETWORK_COUNT, EVENT_COUNT, EVENT_COUNT, cycles,
                (1.0 * aggregate_events) / cycles
            );
        end
    endtask

    task automatic check_learning_isolation;
        logic [ADDR_W-1:0] address;
        begin
            if (NETWORK_COUNT < 2)
                $fatal(1, "learning-isolation test requires at least two networks");

            reset_network({NETWORK_COUNT{1'b1}});
            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++)
                send_event(network_id, ID_W'(0));
            repeat (3) @(posedge clk);

            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++)
                teach_neuron(network_id, target_pe(network_id));

            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++) begin
                if (selected_connection_counts[network_id*5 +: 5] != 5'd1)
                    $fatal(1, "network %0d failed initial learning",
                           network_id);
                address = ADDR_W'(
                    network_id*N*N + target_pe(network_id)*N
                );
                check_synapse(address, 1'b1);
            end
            if ((32'd1 << ADDR_W) > NETWORK_COUNT*N*N)
                check_synapse(ADDR_W'(NETWORK_COUNT*N*N), 1'b0);

            send_event(0, ID_W'(3));
            teach_neuron(0, target_pe(0));
            if (selected_connection_counts[0 +: 5] != 5'd2)
                $fatal(1, "network 0 did not learn its second connection");
            address = ADDR_W'(target_pe(0)*N + 3);
            check_synapse(address, 1'b1);

            for (int network_id = 1;
                 network_id < NETWORK_COUNT;
                 network_id++) begin
                if (selected_connection_counts[network_id*5 +: 5] != 5'd1)
                    $fatal(1, "network 0 learning leaked into network %0d",
                           network_id);
            end

            $display(
                "Learning isolation/readback: network 0 connections=%0d; other network counts remain 1",
                selected_connection_counts[0 +: 5]
            );
        end
    endtask

    initial begin
        if (NETWORK_COUNT < 2)
            $fatal(1, "NETWORK_COUNT must be at least two for this test");
        reset_network('0);
        $display("Running parallel throughput test");
        check_two_stream_throughput();
        $display("Running learning isolation test");
        check_learning_isolation();
        $display("Running exact snapshot test");
        check_exact_snapshot_restore();
        $display("PASS: NETWORK_COUNT=%0d generic BLM fabric", NETWORK_COUNT);
        $finish;
    end

    initial begin
        #200_000;
        $fatal(1, "generic BLM network test timed out");
    end
endmodule
