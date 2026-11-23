/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module eap16_event_router #(
    parameter int N = 16,
    parameter int FIFO_DEPTH = 64,
    parameter bit SNAPSHOT_ACCESS = 1'b0,
    parameter int SNAPSHOT_ADDR_W = $clog2(
        FIFO_DEPTH + N +
        ((($clog2(FIFO_DEPTH+1) +
           2*((FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1) +
           $clog2(N+1) + 1) + 31) / 32)
    )
) (
    input  logic clk,
    input  logic rst,
    input  logic external_valid,
    input  logic [$clog2(N)-1:0] external_source,
    output logic external_ready,
    input  logic [N-1:0] feedback_spikes,
    output logic event_valid,
    output logic [$clog2(N)-1:0] event_source,
    input  logic event_consume,
    output logic overflow,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] level,
    input  logic snapshot_pause,
    input  logic [SNAPSHOT_ADDR_W-1:0] snapshot_addr,
    input  logic snapshot_write_enable,
    input  logic [31:0] snapshot_write_data,
    output logic [31:0] snapshot_read_data
);
    localparam int ID_W = $clog2(N);
    localparam int LEVEL_W = $clog2(FIFO_DEPTH + 1);
    localparam int PTR_W = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
    localparam int PENDING_W = $clog2(FIFO_DEPTH + 1);
    localparam int ARBITER_PORTS = N + 1;
    localparam int ARBITER_W =
        (ARBITER_PORTS > 1) ? $clog2(ARBITER_PORTS) : 1;
    localparam logic [PENDING_W-1:0] PENDING_MAX = PENDING_W'(FIFO_DEPTH);
    localparam int FIFO_STATE_BITS = FIFO_DEPTH;
    localparam int PENDING_STATE_BASE = FIFO_DEPTH;
    localparam int CONTROL_USED_BITS =
        LEVEL_W + 2*PTR_W + ARBITER_W + 1;
    localparam int SNAPSHOT_WORD_BITS = 32;
    localparam int CONTROL_WORDS =
        (CONTROL_USED_BITS + SNAPSHOT_WORD_BITS - 1) / SNAPSHOT_WORD_BITS;
    localparam int CONTROL_STATE_BASE = FIFO_DEPTH + N;
    localparam int ROUTER_STATE_BITS =
        CONTROL_STATE_BASE + CONTROL_WORDS;

    logic [ID_W-1:0] event_mem [0:FIFO_DEPTH-1];
    logic [PENDING_W-1:0] pending_spikes [0:N-1];
    logic [PTR_W-1:0] fifo_mem_read_addr;
    logic [ID_W-1:0] fifo_mem_read_data;
    logic fifo_mem_write_enable;
    logic [PTR_W-1:0] fifo_mem_write_addr;
    logic [ID_W-1:0] fifo_mem_write_data;
    logic snapshot_fifo_access;
    logic [PTR_W:0] snapshot_fifo_distance;
    logic [N:0] arbiter_requests;
    logic [N:0] arbiter_grant;
    logic [N-1:0] spike_grant;
    logic [ID_W-1:0] fifo_write_data;
    logic [LEVEL_W-1:0] fifo_count;
    logic [LEVEL_W-1:0] next_fifo_count;
    logic [PTR_W-1:0] fifo_read_pointer;
    logic [PTR_W-1:0] fifo_write_pointer;
    logic [ARBITER_W-1:0] last_grant;
    logic [N:0] priority_mask;
    logic [N:0] priority_requests;
    logic [ARBITER_W-1:0] selected_port;
    logic fifo_pop;
    logic fifo_push;
    logic fifo_can_push;
    logic external_push;
    logic any_feedback_pending;
    logic selected_valid;
    logic [CONTROL_USED_BITS-1:0] snapshot_control_state;
    logic [CONTROL_USED_BITS-1:0] snapshot_control_next;

    function automatic logic [PTR_W-1:0] increment_pointer(
        input logic [PTR_W-1:0] pointer
    );
        if (pointer == PTR_W'(FIFO_DEPTH - 1))
            increment_pointer = '0;
        else
            increment_pointer = pointer + 1'b1;
    endfunction

    function automatic logic [PTR_W:0] get_snapshot_fifo_distance(
        input logic [SNAPSHOT_ADDR_W-1:0] entry_index,
        input logic [PTR_W-1:0] read_pointer
    );
        logic [PTR_W:0] entry_index_ext;
        logic [PTR_W:0] read_pointer_ext;
        begin
            entry_index_ext = (PTR_W+1)'(entry_index);
            read_pointer_ext = {1'b0, read_pointer};
            if (entry_index_ext >= read_pointer_ext)
                get_snapshot_fifo_distance =
                    entry_index_ext - read_pointer_ext;
            else
                get_snapshot_fifo_distance =
                    (PTR_W+1)'(FIFO_DEPTH) +
                    entry_index_ext - read_pointer_ext;
        end
    endfunction

    assign fifo_mem_read_data = event_mem[fifo_mem_read_addr];
    assign snapshot_fifo_access =
        SNAPSHOT_ACCESS && snapshot_pause &&
        (snapshot_addr < FIFO_STATE_BITS);
    assign snapshot_fifo_distance =
        get_snapshot_fifo_distance(snapshot_addr, fifo_read_pointer);
    assign snapshot_control_state = {
        overflow,
        last_grant,
        fifo_write_pointer,
        fifo_read_pointer,
        fifo_count
    };

    always @* begin
        snapshot_read_data = '0;
        snapshot_control_next = snapshot_control_state;

        if (SNAPSHOT_ACCESS) begin
            if (snapshot_addr < FIFO_STATE_BITS) begin
                if (snapshot_fifo_distance < (PTR_W+1)'(fifo_count))
                    snapshot_read_data[ID_W-1:0] = fifo_mem_read_data;
            end else if (snapshot_addr < CONTROL_STATE_BASE) begin
                snapshot_read_data[PENDING_W-1:0] =
                    pending_spikes[snapshot_addr - PENDING_STATE_BASE];
            end else if (snapshot_addr < ROUTER_STATE_BITS) begin
                if (CONTROL_WORDS == 1) begin
                    // The default control state fits in one word.
                    snapshot_read_data[CONTROL_USED_BITS-1:0] =
                        snapshot_control_state;
                    if (snapshot_pause && snapshot_write_enable)
                        snapshot_control_next[CONTROL_USED_BITS-1:0] =
                            snapshot_write_data[CONTROL_USED_BITS-1:0];
                end else begin
                    for (int bit_index = 0;
                         bit_index < SNAPSHOT_WORD_BITS;
                         bit_index++) begin
                        if (((int'(snapshot_addr) - CONTROL_STATE_BASE) *
                             SNAPSHOT_WORD_BITS + bit_index) <
                            CONTROL_USED_BITS) begin
                            snapshot_read_data[bit_index] =
                                snapshot_control_state[
                                    (int'(snapshot_addr) - CONTROL_STATE_BASE) *
                                        SNAPSHOT_WORD_BITS + bit_index
                                ];
                            if (snapshot_pause && snapshot_write_enable)
                                snapshot_control_next[
                                    (int'(snapshot_addr) - CONTROL_STATE_BASE) *
                                        SNAPSHOT_WORD_BITS + bit_index
                                ] = snapshot_write_data[bit_index];
                        end
                    end
                end
            end
        end
    end

    always @* begin
        event_valid = (fifo_count != '0);
        fifo_mem_read_addr = fifo_read_pointer;
        if (snapshot_fifo_access)
            fifo_mem_read_addr = PTR_W'(snapshot_addr);
        event_source = fifo_mem_read_data;
        level = fifo_count;
        fifo_pop = event_valid && event_consume;
        fifo_can_push = (fifo_count < LEVEL_W'(FIFO_DEPTH)) || fifo_pop;

        // Port 0 is the external input; ports 1..N are feedback source IDs.
        arbiter_requests = '0;
        arbiter_requests[0] = external_valid;
        any_feedback_pending = 1'b0;
        for (int i = 0; i < N; i++) begin
            arbiter_requests[i+1] = (pending_spikes[i] != '0);
            any_feedback_pending =
                any_feedback_pending || (pending_spikes[i] != '0);
        end

        arbiter_grant = '0;
        priority_mask = '0;
        for (int i = 0; i < ARBITER_PORTS; i++)
            priority_mask[i] = ARBITER_W'(i) > last_grant;
        priority_requests = arbiter_requests & priority_mask;
        if (!(|priority_requests))
            priority_requests = arbiter_requests;

        selected_port = '0;
        selected_valid = 1'b0;
        // Prefer requests after the previous grant, then wrap to port zero.
        for (int i = 0; i < ARBITER_PORTS; i++) begin
            if (!selected_valid && priority_requests[i]) begin
                arbiter_grant[i] = 1'b1;
                selected_port = ARBITER_W'(i);
                selected_valid = 1'b1;
            end
        end

        spike_grant = '0;
        for (int i = 0; i < N; i++)
            spike_grant[i] = fifo_can_push && arbiter_grant[i+1];

        external_ready = fifo_can_push &&
                         (arbiter_grant[0] || !any_feedback_pending);
        if (SNAPSHOT_ACCESS && snapshot_pause)
            external_ready = 1'b0;
        external_push = external_valid && external_ready &&
                        arbiter_grant[0];
        fifo_push = external_push || (|spike_grant);
        fifo_write_data = external_source;
        for (int i = 0; i < N; i++) begin
            if (spike_grant[i])
                fifo_write_data = ID_W'(i);
        end

        fifo_mem_write_enable = 1'b0;
        fifo_mem_write_addr = fifo_write_pointer;
        fifo_mem_write_data = fifo_write_data;
        if (SNAPSHOT_ACCESS && snapshot_pause) begin
            if (snapshot_write_enable &&
                snapshot_addr < FIFO_STATE_BITS) begin
                fifo_mem_write_enable = 1'b1;
                fifo_mem_write_addr = PTR_W'(snapshot_addr);
                fifo_mem_write_data = snapshot_write_data[ID_W-1:0];
            end
        end else begin
            fifo_mem_write_enable = fifo_push;
        end

        next_fifo_count = fifo_count - LEVEL_W'(fifo_pop) +
                          LEVEL_W'(fifo_push);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            fifo_read_pointer <= '0;
            fifo_write_pointer <= '0;
            fifo_count <= '0;
            last_grant <= ARBITER_W'(ARBITER_PORTS - 1);
            overflow <= 1'b0;
            for (int i = 0; i < N; i++)
                pending_spikes[i] <= '0;
        end else if (SNAPSHOT_ACCESS && snapshot_pause) begin
            if (snapshot_write_enable) begin
                if (snapshot_addr < FIFO_STATE_BITS) begin
                    if (fifo_mem_write_enable)
                        event_mem[fifo_mem_write_addr] <= fifo_mem_write_data;
                end else if (snapshot_addr < CONTROL_STATE_BASE) begin
                    pending_spikes[snapshot_addr - PENDING_STATE_BASE] <=
                        PENDING_W'(snapshot_write_data);
                end else if (snapshot_addr < ROUTER_STATE_BITS) begin
                    if (CONTROL_WORDS == 1) begin
                        fifo_count <= snapshot_write_data[0 +: LEVEL_W];
                        fifo_read_pointer <=
                            snapshot_write_data[LEVEL_W +: PTR_W];
                        fifo_write_pointer <=
                            snapshot_write_data[LEVEL_W+PTR_W +: PTR_W];
                        last_grant <=
                            snapshot_write_data[LEVEL_W+2*PTR_W +: ARBITER_W];
                        overflow <=
                            snapshot_write_data[
                                LEVEL_W+2*PTR_W+ARBITER_W
                            ];
                    end else begin
                        fifo_count <= snapshot_control_next[0 +: LEVEL_W];
                        fifo_read_pointer <=
                            snapshot_control_next[LEVEL_W +: PTR_W];
                        fifo_write_pointer <=
                            snapshot_control_next[LEVEL_W+PTR_W +: PTR_W];
                        last_grant <=
                            snapshot_control_next[
                                LEVEL_W+2*PTR_W +: ARBITER_W
                            ];
                        overflow <= snapshot_control_next[
                            LEVEL_W+2*PTR_W+ARBITER_W
                        ];
                    end
                end
            end
        end else begin
            if (fifo_pop)
                fifo_read_pointer <= increment_pointer(fifo_read_pointer);
            if (fifo_mem_write_enable) begin
                event_mem[fifo_mem_write_addr] <= fifo_mem_write_data;
            end
            if (fifo_push) begin
                fifo_write_pointer <= increment_pointer(fifo_write_pointer);
                last_grant <= selected_port;
            end
            fifo_count <= next_fifo_count;

            for (int i = 0; i < N; i++) begin
                case ({feedback_spikes[i], spike_grant[i]})
                    2'b10: begin
                        if (pending_spikes[i] != PENDING_MAX)
                            pending_spikes[i] <= pending_spikes[i] + 1'b1;
                        else
                            overflow <= 1'b1;
                    end
                    2'b01:
                        pending_spikes[i] <= pending_spikes[i] - 1'b1;
                    default: begin
                    end
                endcase
            end
        end
    end
endmodule
