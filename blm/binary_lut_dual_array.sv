/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module binary_lut_dual_array #(
    parameter int N = 16,
    parameter int NETWORK_COUNT = 4,
    parameter bit SNAPSHOT_ACCESS = 1'b1,
    parameter bit CONNECTION_COUNTS = 1'b0,
    // The snapshot scan chain covers all synapses; the live mux is opt-in.
    parameter bit SYNAPSE_READ_PORT = 1'b0
) (
    input  logic clk,
    input  logic rst,
    input  logic snapshot_pause,
    input  logic snapshot_shift_enable,
    input  logic snapshot_write_enable,
    input  logic snapshot_write_data,
    output logic snapshot_read_data,
    output logic snapshot_ready,
    input  logic [NETWORK_COUNT-1:0] learning_enable,
    input  logic [NETWORK_COUNT-1:0] event_valid,
    input  logic [NETWORK_COUNT*$clog2(N)-1:0] event_source,
    input  logic [NETWORK_COUNT*$clog2(N)-1:0] event_target_pe,
    input  logic [NETWORK_COUNT-1:0] event_broadcast,
    input  logic [NETWORK_COUNT*$clog2(N)-1:0] selected_pe,
    input  logic [$clog2(NETWORK_COUNT*N*N)-1:0] synapse_read_addr,
    output logic synapse_read_data,
    input  logic [NETWORK_COUNT*N-1:0] teacher_spike,
    input  logic [NETWORK_COUNT-1:0] maintenance_tick,
    output logic [NETWORK_COUNT-1:0] event_ready,
    output logic [NETWORK_COUNT*N-1:0] spikes,
    output logic [NETWORK_COUNT*5-1:0] selected_connection_counts
);
    localparam int ID_W = $clog2(N);
    localparam int SNAPSHOT_BITS_PER_PE = 2*(N - 1) + 4;
    localparam int SNAPSHOT_BITS_PER_NETWORK = N * SNAPSHOT_BITS_PER_PE;
    localparam int SNAPSHOT_TOTAL_BITS =
        NETWORK_COUNT * SNAPSHOT_BITS_PER_NETWORK;

    logic [N*5-1:0] packed_counts [0:NETWORK_COUNT-1];
    logic [N*N-1:0] synapse_map [0:NETWORK_COUNT-1];
    logic [NETWORK_COUNT:0] network_scan_chain;
    logic [NETWORK_COUNT-1:0] array_snapshot_ready;

    assign snapshot_read_data =
        SNAPSHOT_ACCESS ? network_scan_chain[NETWORK_COUNT] : 1'b0;
    assign snapshot_ready = SNAPSHOT_ACCESS && snapshot_pause && !rst;
    // Circular loopback on read (snapshot_write_enable=0) preserves state.
    assign network_scan_chain[0] =
        SNAPSHOT_ACCESS
            ? (snapshot_write_enable ? snapshot_write_data
                                     : snapshot_read_data)
            : 1'b0;

    if (SYNAPSE_READ_PORT) begin : gen_synapse_read_port
        localparam int MAP_DEPTH = NETWORK_COUNT*N*N;
        localparam int ADDR_W = $clog2(MAP_DEPTH);
        localparam int ADDR_EXT_W = ADDR_W + 1;
        localparam logic [ADDR_EXT_W-1:0] MAP_DEPTH_EXT =
            ADDR_EXT_W'(MAP_DEPTH);

        logic [MAP_DEPTH-1:0] flat_synapse_map;
        logic [ADDR_EXT_W-1:0] synapse_read_addr_ext;

        assign synapse_read_addr_ext = {1'b0, synapse_read_addr};
        for (genvar map_id = 0; map_id < NETWORK_COUNT; map_id++) begin : gen_map
            assign flat_synapse_map[map_id*N*N +: N*N] =
                synapse_map[map_id];
        end

        always @* begin
            synapse_read_data = 1'b0;
            if (synapse_read_addr_ext < MAP_DEPTH_EXT)
                synapse_read_data =
                    flat_synapse_map[synapse_read_addr_ext[ADDR_W-1:0]];
        end
    end else begin : gen_no_synapse_read_port
        assign synapse_read_data = 1'b0;
    end

    for (genvar network_id = 0;
         network_id < NETWORK_COUNT;
         network_id++) begin : gen_network
        binary_lut_array #(
            .N(N),
            .COUNT_SELECTED_ONLY(1'b1),
            .COUNT_ENABLE(CONNECTION_COUNTS),
            .SNAPSHOT_ACCESS(SNAPSHOT_ACCESS)
        ) u_array (
            .clk(clk),
            .rst(rst),
            .snapshot_pause(snapshot_pause),
            .snapshot_shift_enable(snapshot_shift_enable),
            .snapshot_in(network_scan_chain[network_id]),
            .snapshot_out(network_scan_chain[network_id + 1]),
            .snapshot_ready(array_snapshot_ready[network_id]),
            .learning_enable(learning_enable[network_id]),
            .event_valid(event_valid[network_id]),
            .event_source(event_source[network_id*ID_W +: ID_W]),
            .event_target_pe(
                event_target_pe[network_id*ID_W +: ID_W]
            ),
            .event_broadcast(event_broadcast[network_id]),
            .selected_pe(selected_pe[network_id*ID_W +: ID_W]),
            .synapse_map(synapse_map[network_id]),
            .teacher_spike(teacher_spike[network_id*N +: N]),
            .maintenance_tick(maintenance_tick[network_id]),
            .event_ready(event_ready[network_id]),
            .spikes(spikes[network_id*N +: N]),
            .packed_connection_counts(packed_counts[network_id])
        );

        assign selected_connection_counts[network_id*5 +: 5] =
            packed_counts[network_id][4:0];
    end
endmodule
