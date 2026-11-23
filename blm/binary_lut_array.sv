/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module binary_lut_array #(
    parameter int N = 16,
    parameter int FIFO_DEPTH = 64,
    parameter bit COUNT_SELECTED_ONLY = 1'b0
) (
    input  logic clk,
    input  logic rst,
    input  logic learning_enable,
    input  logic event_valid,
    input  logic [$clog2(N)-1:0] event_source,
    input  logic [$clog2(N)-1:0] selected_pe,
    input  logic [N-1:0] teacher_spike,
    input  logic maintenance_tick,
    output logic event_ready,
    output logic event_overflow,
    output logic [N-1:0] spikes,
    output logic [N*5-1:0] packed_connection_counts
);
    localparam int ID_W = $clog2(N);
    localparam int LEVEL_W = $clog2(FIFO_DEPTH + 1);

    logic routed_event_valid;
    logic [ID_W-1:0] routed_event_source;
    logic [N-1:0] routed_event_source_onehot;
    logic [LEVEL_W-1:0] event_fifo_level;
    logic [N-1:0] connection_mask_by_pe [0:N-1];

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

    eap16_event_router #(
        .N(N),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) event_router (
        .clk(clk),
        .rst(rst),
        .external_valid(event_valid),
        .external_source(event_source),
        .external_ready(event_ready),
        .feedback_spikes(spikes),
        .event_valid(routed_event_valid),
        .event_source(routed_event_source),
        .event_consume(routed_event_valid),
        .overflow(event_overflow),
        .level(event_fifo_level)
    );

    for (genvar s = 0; s < N; s++) begin : gen_source_decode
        assign routed_event_source_onehot[s] =
            routed_event_valid && routed_event_source == ID_W'(s);
    end

    for (genvar g = 0; g < N; g++) begin : gen_pe
        binary_lut_pe #(
            .PE_ID(g),
            .N(N)
        ) u_pe (
            .clk(clk),
            .rst(rst),
            .learning_enable(learning_enable),
            .event_source_onehot(routed_event_source_onehot),
            .teacher_spike(teacher_spike[g]),
            .maintenance_tick(maintenance_tick),
            .spike(spikes[g]),
            .membrane_state(),
            .synapse_mask(connection_mask_by_pe[g])
        );
    end

    if (COUNT_SELECTED_ONLY) begin : gen_selected_count
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
