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
    localparam int ID_W = $clog2(N);
    localparam int ADDR_W = $clog2(NETWORK_COUNT*N*N);
    localparam int PE_STATE_WORDS = 2*N;
    localparam int SNAPSHOT_WORDS = NETWORK_COUNT*PE_STATE_WORDS;
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
    logic [NETWORK_COUNT*ID_W-1:0] event_target_pe = '0;
    logic [NETWORK_COUNT*ID_W-1:0] selected_pe = '0;
    logic [ADDR_W-1:0] synapse_read_addr = '0;
    logic synapse_read_data;
    logic [NETWORK_COUNT-1:0] event_ready;
    logic [NETWORK_COUNT*N-1:0] teacher_spike = '0;
    logic [NETWORK_COUNT-1:0] maintenance_tick = '0;
    logic [NETWORK_COUNT*N-1:0] spikes;
    logic [NETWORK_COUNT*5-1:0] selected_connection_counts;

    always #5 clk = ~clk;

    function automatic integer target_pe(input integer network_id);
        target_pe = (network_id % (N - 1)) + 1;
    endfunction

    binary_lut_dual_array #(
        .N(N),
        .NETWORK_COUNT(NETWORK_COUNT),
        .SNAPSHOT_ACCESS(1'b1),
        .CONNECTION_COUNTS(1'b1),
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
        .event_target_pe(event_target_pe),
        .selected_pe(selected_pe),
        .synapse_read_addr(synapse_read_addr),
        .synapse_read_data(synapse_read_data),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .event_ready(event_ready),
        .spikes(spikes),
        .selected_connection_counts(selected_connection_counts)
    );

    task automatic reset_network(input logic [NETWORK_COUNT-1:0] learning);
        begin
            @(negedge clk);
            rst = 1'b1;
            snapshot_pause = 1'b0;
            snapshot_write_enable = 1'b0;
            learning_enable = learning;
            event_valid = '0;
            event_source = '0;
            event_target_pe = '0;
            teacher_spike = '0;
            maintenance_tick = '0;
            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++)
                selected_pe[network_id*ID_W +: ID_W] =
                    ID_W'(target_pe(network_id));
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    task automatic send_event(
        input int network_id,
        input int pe_id,
        input logic [ID_W-1:0] source
    );
        logic accepted;
        integer waits;
        begin
            @(negedge clk);
            event_source[network_id*ID_W +: ID_W] = source;
            event_target_pe[network_id*ID_W +: ID_W] = ID_W'(pe_id);
            event_valid[network_id] = 1'b1;
            accepted = 1'b0;
            waits = 0;
            while (!accepted) begin
                @(posedge clk);
                accepted = event_ready[network_id];
                #1;
                waits = waits + 1;
                if (waits > 4)
                    $fatal(1, "network %0d PE %0d input stayed backpressured",
                           network_id, pe_id);
            end
            @(negedge clk);
            event_valid[network_id] = 1'b0;
        end
    endtask

    task automatic teach_neuron(input int network_id, input int pe_id);
        integer index;
        begin
            index = network_id*N + pe_id;
            @(negedge clk);
            teacher_spike[index] = 1'b1;
            @(posedge clk);
            #1;
            teacher_spike[index] = 1'b0;
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

    task automatic check_pe_stream_throughput;
        integer accepted [0:NETWORK_COUNT-1];
        integer stalls [0:NETWORK_COUNT-1];
        integer cycles;
        integer completed_count;
        integer total_events;
        logic [ID_W-1:0] expected_source;
        logic [ID_W-1:0] expected_target;
        begin
            reset_network('0);
            cycles = 0;
            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++) begin
                accepted[network_id] = 0;
                stalls[network_id] = 0;
            end

            @(negedge clk);
            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++) begin
                event_valid[network_id] = 1'b1;
                event_target_pe[network_id*ID_W +: ID_W] =
                    ID_W'(network_id);
                event_source[network_id*ID_W +: ID_W] =
                    ID_W'((network_id + 3) % N);
            end

            completed_count = 0;
            while (completed_count < NETWORK_COUNT) begin
                @(posedge clk);
                cycles = cycles + 1;
                for (int network_id = 0;
                     network_id < NETWORK_COUNT;
                     network_id++) begin
                    if (event_valid[network_id]) begin
                        expected_target =
                            ID_W'((network_id + accepted[network_id]) % N);
                        expected_source =
                            ID_W'((network_id + accepted[network_id] + 3) % N);
                        if (!event_ready[network_id])
                            stalls[network_id] = stalls[network_id] + 1;
                        if (event_target_pe[network_id*ID_W +: ID_W] !==
                                expected_target ||
                            event_source[network_id*ID_W +: ID_W] !==
                                expected_source)
                            $fatal(1, "network %0d addressed event changed",
                                   network_id);
                        accepted[network_id] =
                            accepted[network_id] + event_ready[network_id];
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
                        event_target_pe[network_id*ID_W +: ID_W] =
                            ID_W'((network_id + accepted[network_id]) % N);
                        event_source[network_id*ID_W +: ID_W] =
                            ID_W'((network_id + accepted[network_id] + 3) % N);
                    end else begin
                        event_valid[network_id] = 1'b0;
                        completed_count = completed_count + 1;
                    end
                end
            end

            total_events = NETWORK_COUNT*EVENT_COUNT;
            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++) begin
                if (accepted[network_id] != EVENT_COUNT)
                    $fatal(1, "network %0d lost an addressed event",
                           network_id);
                if (stalls[network_id] != 0)
                    $fatal(1, "network %0d unexpectedly stalled",
                           network_id);
            end

            $display(
                "%0d addressed network streams accepted %0d events each in %0d cycles (%0d aggregate events/cycle)",
                NETWORK_COUNT, EVENT_COUNT, cycles, total_events/cycles
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
                 network_id++) begin
                send_event(network_id, target_pe(network_id), ID_W'(0));
                teach_neuron(network_id, target_pe(network_id));
                if (selected_connection_counts[network_id*5 +: 5] != 5'd1)
                    $fatal(1, "network %0d failed initial learning",
                           network_id);
                address = ADDR_W'(
                    network_id*N*N + target_pe(network_id)*N
                );
                check_synapse(address, 1'b1);
            end

            send_event(0, target_pe(0), ID_W'(3));
            teach_neuron(0, target_pe(0));
            if (selected_connection_counts[0 +: 5] != 5'd2)
                $fatal(1, "network 0 did not learn its second source");
            check_synapse(ADDR_W'(target_pe(0)*N + 3), 1'b1);

            for (int network_id = 1;
                 network_id < NETWORK_COUNT;
                 network_id++) begin
                if (selected_connection_counts[network_id*5 +: 5] != 5'd1)
                    $fatal(1, "network 0 learning leaked into network %0d",
                           network_id);
            end

            $display("Learning isolation: each network retained its own PE state");
        end
    endtask

    task automatic check_simultaneous_spike_broadcast;
        begin
            reset_network({NETWORK_COUNT{1'b1}});
            @(negedge clk);
            teacher_spike[0] = 1'b1;
            teacher_spike[2] = 1'b1;
            @(posedge clk);
            #1;
            if (spikes[0] !== 1'b1 || spikes[2] !== 1'b1)
                $fatal(1, "simultaneous teacher spikes were not generated");

            @(negedge clk);
            teacher_spike = '0;
            @(posedge clk);
            #1;
            if (dut.gen_network[0].u_array.gen_pe[1].u_pe.candidate_pre[0]
                    !== 1'b1 ||
                dut.gen_network[0].u_array.gen_pe[1].u_pe.candidate_pre[2]
                    !== 1'b1)
                $fatal(1, "simultaneous spikes were not combined at PE 1");
            if (dut.gen_network[0].u_array.gen_pe[0].u_pe.candidate_pre[0]
                    !== 1'b0 ||
                dut.gen_network[0].u_array.gen_pe[2].u_pe.candidate_pre[2]
                    !== 1'b0)
                $fatal(1, "spike broadcast allowed self-traces");
            $display("Simultaneous spikes were broadcast as one multi-hot event mask");
        end
    endtask

    task automatic check_exact_snapshot_restore;
        integer target;
        integer held_network;
        logic accepted;
        integer waits;
        begin
            reset_network({NETWORK_COUNT{1'b1}});
            target = target_pe(0);
            send_event(0, target, ID_W'(0));
            repeat (2) @(posedge clk);
            teach_neuron(0, target);
            if (selected_connection_counts[0 +: 5] != 5'd1)
                $fatal(1, "snapshot setup failed to learn source 0");

            held_network = 1;
            @(negedge clk);
            event_valid[held_network] = 1'b1;
            event_target_pe[held_network*ID_W +: ID_W] =
                ID_W'(target_pe(held_network));
            event_source[held_network*ID_W +: ID_W] = ID_W'(5);
            snapshot_pause = 1'b1;
            @(posedge clk);
            #1;
            if (event_ready !== '0)
                $fatal(1, "pause did not backpressure PE inputs");

            read_snapshot();
            $display("snapshot PE%0d words: %08x %08x",
                     target, saved_snapshot[target*2],
                     saved_snapshot[target*2 + 1]);
            if (saved_snapshot[target*2][N-1:0] !== 16'h0001)
                $fatal(1, "snapshot missed a learned synapse: %04x",
                       saved_snapshot[target*2][N-1:0]);
            if (!saved_snapshot[target*2][N])
                $fatal(1, "snapshot missed the candidate pre-trace");
            if (saved_snapshot[target*2 + 1][31:4] !== 28'b0)
                $fatal(1, "snapshot PE-state padding bits were not zero");

            @(negedge clk);
            snapshot_state_addr = SNAPSHOT_ADDR_W'(target*2);
            snapshot_write_data = saved_snapshot[target*2] ^ 32'b1;
            snapshot_write_enable = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            snapshot_write_enable = 1'b0;
            snapshot_state_addr = SNAPSHOT_ADDR_W'(target*2);
            #1;
            if (snapshot_read_data[0] !== 1'b0)
                $fatal(1, "snapshot test did not corrupt the target bit");

            restore_snapshot();
            verify_snapshot();

            @(negedge clk);
            snapshot_pause = 1'b0;
            accepted = 1'b0;
            waits = 0;
            while (!accepted) begin
                @(posedge clk);
                accepted = event_ready[held_network];
                #1;
                waits = waits + 1;
                if (waits > 4)
                    $fatal(1, "PE input did not resume after snapshot");
            end
            @(negedge clk);
            event_valid[held_network] = 1'b0;

            $display(
                "Exact PE-state snapshot: saved/restored %0d words across %0d networks",
                SNAPSHOT_WORDS, NETWORK_COUNT
            );
        end
    endtask

    initial begin
        if (NETWORK_COUNT < 2)
            $fatal(1, "NETWORK_COUNT must be at least two for this test");
        reset_network('0);
        check_pe_stream_throughput();
        check_simultaneous_spike_broadcast();
        check_learning_isolation();
        check_exact_snapshot_restore();
        $display("PASS: NETWORK_COUNT=%0d PE-addressable BLM fabric",
                 NETWORK_COUNT);
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "dual-array test timed out");
    end
endmodule
