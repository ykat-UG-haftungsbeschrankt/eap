/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module binary_lut_dual_array #(
    parameter int N = 16,
    parameter int NETWORK_COUNT = 2,
    parameter bit SNAPSHOT_ACCESS = 1'b0,
    parameter bit CONNECTION_COUNTS = 1'b0,
    // The snapshot map contains synapses; the extra live mux is opt-in.
    parameter bit SYNAPSE_READ_PORT = 1'b0,
    parameter int SNAPSHOT_WORDS_PER_NETWORK = 2*N,
    parameter int SNAPSHOT_ADDR_W =
        $clog2(NETWORK_COUNT*SNAPSHOT_WORDS_PER_NETWORK)
) (
    input  logic clk,
    input  logic rst,
    input  logic snapshot_pause,
    input  logic [SNAPSHOT_ADDR_W-1:0] snapshot_state_addr,
    input  logic snapshot_write_enable,
    input  logic [31:0] snapshot_write_data,
    output logic [31:0] snapshot_read_data,
    output logic snapshot_write_ready,
    input  logic [NETWORK_COUNT-1:0] learning_enable,
    input  logic [NETWORK_COUNT-1:0] event_valid,
    input  logic [NETWORK_COUNT*$clog2(N)-1:0] event_source,
    input  logic [NETWORK_COUNT*$clog2(N)-1:0] event_target_pe,
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
    localparam int ARRAY_STATE_WORDS = SNAPSHOT_WORDS_PER_NETWORK;
    localparam int ARRAY_STATE_ADDR_W = $clog2(ARRAY_STATE_WORDS + 1);
    localparam int TOTAL_STATE_WORDS = NETWORK_COUNT*ARRAY_STATE_WORDS;
    localparam int TOTAL_STATE_ADDR_EXT_W = SNAPSHOT_ADDR_W + 1;
    localparam logic [TOTAL_STATE_ADDR_EXT_W-1:0] TOTAL_STATE_WORDS_EXT =
        TOTAL_STATE_ADDR_EXT_W'(TOTAL_STATE_WORDS);

    logic [N*5-1:0] packed_counts [0:NETWORK_COUNT-1];
    logic [N*N-1:0] synapse_map [0:NETWORK_COUNT-1];
    logic [ARRAY_STATE_ADDR_W-1:0] array_snapshot_addr [0:NETWORK_COUNT-1];
    logic [31:0] array_snapshot_read_data [0:NETWORK_COUNT-1];
    logic [NETWORK_COUNT-1:0] array_snapshot_write_ready;
    logic [NETWORK_COUNT-1:0] array_snapshot_write_enable;
    logic [TOTAL_STATE_ADDR_EXT_W-1:0] snapshot_state_addr_ext;

    assign snapshot_state_addr_ext = {1'b0, snapshot_state_addr};

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

    always @* begin
        snapshot_read_data = '0;
        if (SNAPSHOT_ACCESS &&
            snapshot_state_addr_ext < TOTAL_STATE_WORDS_EXT) begin
            for (int network_id = 0;
                 network_id < NETWORK_COUNT;
                 network_id++) begin
                if (snapshot_state_addr_ext >=
                        TOTAL_STATE_ADDR_EXT_W'(network_id*ARRAY_STATE_WORDS) &&
                    snapshot_state_addr_ext <
                        TOTAL_STATE_ADDR_EXT_W'((network_id+1)*ARRAY_STATE_WORDS))
                    snapshot_read_data =
                        array_snapshot_read_data[network_id];
            end
        end
        snapshot_write_ready =
            SNAPSHOT_ACCESS && snapshot_pause && !rst &&
            (snapshot_state_addr_ext < TOTAL_STATE_WORDS_EXT);
    end

    for (genvar network_id = 0;
         network_id < NETWORK_COUNT;
         network_id++) begin : gen_network
        localparam int ARRAY_STATE_BASE = network_id * ARRAY_STATE_WORDS;

        binary_lut_array #(
            .N(N),
            .COUNT_SELECTED_ONLY(1'b1),
            .COUNT_ENABLE(CONNECTION_COUNTS),
            .SNAPSHOT_ACCESS(SNAPSHOT_ACCESS),
            .SNAPSHOT_ADDR_W(ARRAY_STATE_ADDR_W)
        ) u_array (
            .clk(clk),
            .rst(rst),
            .snapshot_pause(snapshot_pause),
            .snapshot_addr(array_snapshot_addr[network_id]),
            .snapshot_write_enable(array_snapshot_write_enable[network_id]),
            .snapshot_write_data(snapshot_write_data),
            .snapshot_read_data(array_snapshot_read_data[network_id]),
            .snapshot_write_ready(array_snapshot_write_ready[network_id]),
            .learning_enable(learning_enable[network_id]),
            .event_valid(event_valid[network_id]),
            .event_source(event_source[network_id*ID_W +: ID_W]),
            .event_target_pe(
                event_target_pe[network_id*ID_W +: ID_W]
            ),
            .event_broadcast(1'b0),
            .selected_pe(selected_pe[network_id*ID_W +: ID_W]),
            .synapse_map(synapse_map[network_id]),
            .teacher_spike(teacher_spike[network_id*N +: N]),
            .maintenance_tick(maintenance_tick[network_id]),
            .event_ready(event_ready[network_id]),
            .spikes(spikes[network_id*N +: N]),
            .packed_connection_counts(packed_counts[network_id])
        );

        assign array_snapshot_addr[network_id] =
            ARRAY_STATE_ADDR_W'(
                snapshot_state_addr -
                SNAPSHOT_ADDR_W'(ARRAY_STATE_BASE)
            );
        assign array_snapshot_write_enable[network_id] =
            SNAPSHOT_ACCESS && snapshot_write_enable &&
            snapshot_write_ready &&
            snapshot_state_addr_ext >=
                TOTAL_STATE_ADDR_EXT_W'(ARRAY_STATE_BASE) &&
            snapshot_state_addr_ext <
                TOTAL_STATE_ADDR_EXT_W'(ARRAY_STATE_BASE + ARRAY_STATE_WORDS);

        assign selected_connection_counts[network_id*5 +: 5] =
            packed_counts[network_id][4:0];
    end
endmodule
