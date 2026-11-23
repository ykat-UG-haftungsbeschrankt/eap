/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module binary_lut_array #(
    parameter int N = 16,
    parameter bit COUNT_SELECTED_ONLY = 1'b0,
    parameter bit COUNT_ENABLE = 1'b1,
    parameter bit SNAPSHOT_ACCESS = 1'b0,
    parameter int SNAPSHOT_ADDR_W = $clog2(2*N + 1)
) (
    input  logic clk,
    input  logic rst,
    input  logic learning_enable,
    input  logic event_valid,
    input  logic [$clog2(N)-1:0] event_source,
    input  logic [$clog2(N)-1:0] event_target_pe,
    input  logic event_broadcast,
    input  logic [$clog2(N)-1:0] selected_pe,
    output logic [N*N-1:0] synapse_map,
    input  logic snapshot_pause,
    input  logic [SNAPSHOT_ADDR_W-1:0] snapshot_addr,
    input  logic snapshot_write_enable,
    input  logic [31:0] snapshot_write_data,
    output logic [31:0] snapshot_read_data,
    output logic snapshot_write_ready,
    input  logic [N-1:0] teacher_spike,
    input  logic maintenance_tick,
    output logic event_ready,
    output logic [N-1:0] spikes,
    output logic [N*5-1:0] packed_connection_counts
);
    localparam int ID_W = $clog2(N);
    localparam int PE_STATE_WORDS = 2*N;
    localparam int ARRAY_STATE_WORDS = PE_STATE_WORDS;

    logic [N-1:0] pe_event_source_mask [0:N-1];
    logic [N-1:0] connection_mask_by_pe [0:N-1];
    logic [2*N-1:0] pe_snapshot_word0 [0:N-1];
    logic [3:0] pe_snapshot_word1 [0:N-1];
    logic [N-1:0] pe_snapshot_write_word0;
    logic [N-1:0] pe_snapshot_write_word1;
    logic [N-1:0] external_event_source_onehot;
    logic event_target_valid;
    integer pe_snapshot_index;

    function automatic logic [4:0] count_connections(
        input logic [N-1:0] mask
    );
        logic [15:0] padded;
        logic [1:0] pair0;
        logic [1:0] pair1;
        logic [1:0] pair2;
        logic [1:0] pair3;
        logic [1:0] pair4;
        logic [1:0] pair5;
        logic [1:0] pair6;
        logic [1:0] pair7;
        logic [2:0] quad0;
        logic [2:0] quad1;
        logic [2:0] quad2;
        logic [2:0] quad3;
        logic [3:0] half0;
        logic [3:0] half1;
        begin
            padded = '0;
            for (int i = 0; i < N; i++) begin
                padded[i] = mask[i];
            end

            pair0 = {1'b0, padded[0]} + {1'b0, padded[1]};
            pair1 = {1'b0, padded[2]} + {1'b0, padded[3]};
            pair2 = {1'b0, padded[4]} + {1'b0, padded[5]};
            pair3 = {1'b0, padded[6]} + {1'b0, padded[7]};
            pair4 = {1'b0, padded[8]} + {1'b0, padded[9]};
            pair5 = {1'b0, padded[10]} + {1'b0, padded[11]};
            pair6 = {1'b0, padded[12]} + {1'b0, padded[13]};
            pair7 = {1'b0, padded[14]} + {1'b0, padded[15]};

            quad0 = {1'b0, pair0} + {1'b0, pair1};
            quad1 = {1'b0, pair2} + {1'b0, pair3};
            quad2 = {1'b0, pair4} + {1'b0, pair5};
            quad3 = {1'b0, pair6} + {1'b0, pair7};

            half0 = {1'b0, quad0} + {1'b0, quad1};
            half1 = {1'b0, quad2} + {1'b0, quad3};
            count_connections = {1'b0, half0} + {1'b0, half1};
        end
    endfunction

    assign event_target_valid = int'(event_target_pe) < N;
    assign event_ready =
        !rst && !(SNAPSHOT_ACCESS && snapshot_pause) &&
        (!event_valid || event_broadcast || event_target_valid);

    for (genvar s = 0; s < N; s++) begin : gen_source_decode
        assign external_event_source_onehot[s] =
            event_valid && event_source == ID_W'(s);
    end

    for (genvar g = 0; g < N; g++) begin : gen_pe
        // All spikes are combined as a multi-hot event mask for every PE.
        assign pe_event_source_mask[g] =
            (external_event_source_onehot &
             {N{event_broadcast ||
                event_target_pe == ID_W'(g)}}) | spikes;

        binary_lut_pe #(
            .PE_ID(g),
            .N(N)
        ) u_pe (
            .clk(clk),
            .rst(rst),
            .learning_enable(learning_enable),
            .snapshot_pause(SNAPSHOT_ACCESS && snapshot_pause),
            .snapshot_write_word0(pe_snapshot_write_word0[g]),
            .snapshot_write_word1(pe_snapshot_write_word1[g]),
            .snapshot_write_data(snapshot_write_data),
            .snapshot_read_word0(pe_snapshot_word0[g]),
            .snapshot_read_word1(pe_snapshot_word1[g]),
            .event_source_mask(pe_event_source_mask[g]),
            .teacher_spike(teacher_spike[g]),
            .maintenance_tick(maintenance_tick),
            .spike(spikes[g]),
            .membrane_state(),
            .synapse_mask(connection_mask_by_pe[g])
        );

        // Row g is the target PE; each bit is one source PE.
        assign synapse_map[g*N +: N] = connection_mask_by_pe[g];
    end

    if (SNAPSHOT_ACCESS) begin : gen_snapshot_access
        for (genvar g = 0; g < N; g++) begin : gen_pe_state_access
            localparam int PE_STATE_BASE = g * 2;
            assign pe_snapshot_write_word0[g] =
                snapshot_pause && snapshot_write_enable &&
                snapshot_addr == SNAPSHOT_ADDR_W'(PE_STATE_BASE);
            assign pe_snapshot_write_word1[g] =
                snapshot_pause && snapshot_write_enable &&
                snapshot_addr == SNAPSHOT_ADDR_W'(PE_STATE_BASE + 1);
        end

        always @* begin
            snapshot_read_data = '0;
            snapshot_write_ready =
                snapshot_pause && !rst &&
                snapshot_addr < SNAPSHOT_ADDR_W'(ARRAY_STATE_WORDS);
            pe_snapshot_index = 0;
            if (snapshot_addr < SNAPSHOT_ADDR_W'(PE_STATE_WORDS)) begin
                pe_snapshot_index = snapshot_addr >> 1;
                if (snapshot_addr[0])
                    snapshot_read_data[3:0] =
                        pe_snapshot_word1[pe_snapshot_index];
                else
                    snapshot_read_data[2*N-1:0] =
                        pe_snapshot_word0[pe_snapshot_index];
            end
        end
    end else begin : gen_no_snapshot_access
        assign snapshot_read_data = '0;
        assign snapshot_write_ready = 1'b0;
        for (genvar g = 0; g < N; g++) begin : gen_pe_state_defaults
            assign pe_snapshot_write_word0[g] = 1'b0;
            assign pe_snapshot_write_word1[g] = 1'b0;
        end
    end

    if (!COUNT_ENABLE) begin : gen_no_connection_count
        assign packed_connection_counts = '0;
    end else if (COUNT_SELECTED_ONLY) begin : gen_selected_count
        logic [N-1:0] selected_pe_onehot;
        logic [N-1:0] selected_connection_mask;
        logic [4:0] selected_connection_count;

        always @* begin
            selected_pe_onehot = '0;
            selected_connection_mask = '0;
            for (int p = 0; p < N; p++) begin
                selected_pe_onehot[p] = selected_pe == ID_W'(p);
                selected_connection_mask =
                    selected_connection_mask |
                    (connection_mask_by_pe[p] &
                     {N{selected_pe_onehot[p]}});
            end
            selected_connection_count =
                count_connections(selected_connection_mask);
        end

        for (genvar p = 0; p < N; p++) begin : gen_repeated_count
            assign packed_connection_counts[p*5 +: 5] =
                selected_connection_count;
        end
    end else begin : gen_all_counts
        for (genvar p = 0; p < N; p++) begin : gen_per_pe_count
            assign packed_connection_counts[p*5 +: 5] =
                count_connections(connection_mask_by_pe[p]);
        end
    end
endmodule
