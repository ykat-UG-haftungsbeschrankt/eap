/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

// Minimal binary UART command and scan-chain snapshot bridge for BLM arrays.
//
// Binary protocol (115200 8N1 by default):
//   0x00                   PING           -> replies 0x55
//   0x1n (n=0..NETS-1)     SELECT_NET     -> selects active network, replies 0x1n
//   0x2x (x[0]=learn)      LEARN_MODE     -> sets learning_enable[net], replies 0x2x
//   0x30 {pe[3:0],src[3:0]} EVENT         -> sends PE-addressed event, replies 0x30
//   0x31 {4'b0,src[3:0]}    BCAST_EVENT   -> broadcasts source event, replies 0x31
//   0x4p (p=0..N-1)        TEACH          -> pulses teacher_spike[net,p], replies 0x4p
//   0x50                   TICK           -> pulses maintenance_tick[net], replies 0x50
//   0x60                   READ_SPIKES    -> replies 2 bytes (spikes[7:0], [15:8]) & clears
//   0x70                   SNAPSHOT_SAVE  -> pauses, streams SNAPSHOT_BYTES bytes (circular)
//   0x71 <SNAPSHOT_BYTES>  SNAPSHOT_LOAD  -> pauses, loads SNAPSHOT_BYTES bytes, replies 0x71
//   0x72 / 0x73            PAUSE_ON / OFF -> sets manual pause, replies 0x72 / 0x73
//   error replies: 0xFE (invalid argument or paused), 0xFF (unknown opcode)
module blm_uart_bridge #(
    parameter int N = 16,
    parameter int NETWORK_COUNT = 4,
    parameter int UART_CLOCK_HZ = 13_500_000,
    parameter int UART_BAUD_RATE = 115_200
) (
    input  logic clk,
    input  logic rst,
    input  logic uart_rx_pin,
    output logic uart_tx_pin,
    output logic snapshot_pause,
    output logic snapshot_shift_enable,
    output logic snapshot_write_enable,
    output logic snapshot_write_data,
    input  logic snapshot_read_data,
    input  logic snapshot_ready,
    output logic [NETWORK_COUNT-1:0] learning_enable,
    output logic [NETWORK_COUNT-1:0] event_valid,
    output logic [NETWORK_COUNT*$clog2(N)-1:0] event_source,
    output logic [NETWORK_COUNT*$clog2(N)-1:0] event_target_pe,
    output logic [NETWORK_COUNT-1:0] event_broadcast,
    output logic [NETWORK_COUNT*N-1:0] teacher_spike,
    output logic [NETWORK_COUNT-1:0] maintenance_tick,
    input  logic [NETWORK_COUNT-1:0] event_ready,
    input  logic [NETWORK_COUNT*N-1:0] spikes,
    output logic [1:0] active_network_out
);
    localparam int ID_W = $clog2(N);
    localparam int NET_W = (NETWORK_COUNT > 1) ? $clog2(NETWORK_COUNT) : 1;
    localparam int SNAPSHOT_BITS_PER_PE = 2*(N - 1) + 4;
    localparam int SNAPSHOT_TOTAL_BITS =
        NETWORK_COUNT * N * SNAPSHOT_BITS_PER_PE;
    localparam int SNAPSHOT_BYTES = (SNAPSHOT_TOTAL_BITS + 7) / 8;
    localparam int BYTE_CNT_W = $clog2(SNAPSHOT_BYTES + 1);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_EVENT_ARG,
        ST_TX_BYTE,
        ST_TX_SPIKE_HI,
        ST_SNAP_SAVE_SHIFT,
        ST_SNAP_SAVE_TX,
        ST_SNAP_LOAD_RX,
        ST_SNAP_LOAD_SHIFT
    } state_t;

    state_t state;
    logic [7:0] rx_data;
    logic rx_valid;
    logic rx_framing_error;
    logic [7:0] tx_data;
    logic tx_valid;
    logic tx_ready;

    logic [NET_W-1:0] active_net;
    logic manual_pause;
    logic pending_broadcast;
    logic [7:0] reply_byte;
    logic [7:0] shift_byte;
    logic [2:0] bit_pos;
    logic [BYTE_CNT_W-1:0] byte_count;
    logic [15:0] latched_spikes;
    logic [ID_W-1:0] shared_event_source;
    logic [ID_W-1:0] shared_event_target_pe;
    logic [N-1:0] active_spikes;
    logic snap_active;

    uart_rx #(
        .CLOCK_HZ(UART_CLOCK_HZ),
        .BAUD_RATE(UART_BAUD_RATE)
    ) receiver (
        .clk(clk),
        .rst(rst),
        .rx_pin(uart_rx_pin),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .framing_error(rx_framing_error)
    );

    uart_tx #(
        .CLOCK_HZ(UART_CLOCK_HZ),
        .BAUD_RATE(UART_BAUD_RATE)
    ) transmitter (
        .clk(clk),
        .rst(rst),
        .tx_data(tx_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_pin(uart_tx_pin)
    );

    assign snap_active =
        (state == ST_SNAP_SAVE_SHIFT) ||
        (state == ST_SNAP_SAVE_TX) ||
        (state == ST_SNAP_LOAD_RX) ||
        (state == ST_SNAP_LOAD_SHIFT);

    assign snapshot_pause = manual_pause || snap_active;
    assign snapshot_shift_enable =
        snapshot_ready &&
        ((state == ST_SNAP_SAVE_SHIFT) || (state == ST_SNAP_LOAD_SHIFT));
    assign snapshot_write_enable = (state == ST_SNAP_LOAD_SHIFT);
    assign snapshot_write_data = shift_byte[0];
    assign active_network_out = 2'(active_net);

    for (genvar k = 0; k < NETWORK_COUNT; k++) begin : gen_shared_bus
        assign event_source[k*ID_W +: ID_W] = shared_event_source;
        assign event_target_pe[k*ID_W +: ID_W] = shared_event_target_pe;
    end

    always @* begin
        active_spikes = '0;
        for (int k = 0; k < NETWORK_COUNT; k++) begin
            if (active_net == NET_W'(k))
                active_spikes = spikes[k*N +: N];
        end
    end

    always @* begin
        tx_valid = 1'b0;
        tx_data = reply_byte;
        if (state == ST_TX_BYTE || state == ST_TX_SPIKE_HI) begin
            tx_valid = 1'b1;
            tx_data = reply_byte;
        end else if (state == ST_SNAP_SAVE_TX) begin
            tx_valid = 1'b1;
            tx_data = shift_byte;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            active_net <= '0;
            manual_pause <= 1'b0;
            pending_broadcast <= 1'b0;
            reply_byte <= 8'h00;
            shift_byte <= 8'h00;
            bit_pos <= 3'd0;
            byte_count <= '0;
            latched_spikes <= 16'h0000;
            learning_enable <= {NETWORK_COUNT{1'b1}};
            event_valid <= '0;
            event_broadcast <= '0;
            teacher_spike <= '0;
            maintenance_tick <= '0;
            shared_event_source <= '0;
            shared_event_target_pe <= '0;
        end else begin
            // One-cycle pulses default low each cycle.
            event_valid <= '0;
            event_broadcast <= '0;
            teacher_spike <= '0;
            maintenance_tick <= '0;

            if (!snapshot_pause) begin
                for (int b = 0; b < N; b++) begin
                    if (active_spikes[b])
                        latched_spikes[b] <= 1'b1;
                end
            end

            case (state)
                ST_IDLE: begin
                    if (rx_valid) begin
                        if (rx_data == 8'h00) begin
                            reply_byte <= 8'h55;
                            state <= ST_TX_BYTE;
                        end else if (rx_data[7:4] == 4'h1) begin
                            if (int'(rx_data[3:0]) < NETWORK_COUNT) begin
                                active_net <= NET_W'(rx_data[3:0]);
                                latched_spikes <= 16'h0000;
                                reply_byte <= rx_data;
                            end else begin
                                reply_byte <= 8'hFE;
                            end
                            state <= ST_TX_BYTE;
                        end else if (rx_data[7:4] == 4'h2) begin
                            for (int k = 0; k < NETWORK_COUNT; k++) begin
                                if (active_net == NET_W'(k))
                                    learning_enable[k] <= rx_data[0];
                            end
                            reply_byte <= rx_data;
                            state <= ST_TX_BYTE;
                        end else if (rx_data == 8'h30 || rx_data == 8'h31) begin
                            pending_broadcast <= rx_data[0];
                            state <= ST_EVENT_ARG;
                        end else if (rx_data[7:4] == 4'h4) begin
                            if (!manual_pause && int'(rx_data[3:0]) < N) begin
                                for (int k = 0; k < NETWORK_COUNT; k++) begin
                                    if (active_net == NET_W'(k))
                                        teacher_spike[k*N +: N] <=
                                            N'(1) << rx_data[ID_W-1:0];
                                end
                                reply_byte <= rx_data;
                            end else begin
                                reply_byte <= 8'hFE;
                            end
                            state <= ST_TX_BYTE;
                        end else if (rx_data == 8'h50) begin
                            if (!manual_pause) begin
                                for (int k = 0; k < NETWORK_COUNT; k++) begin
                                    if (active_net == NET_W'(k))
                                        maintenance_tick[k] <= 1'b1;
                                end
                                reply_byte <= 8'h50;
                            end else begin
                                reply_byte <= 8'hFE;
                            end
                            state <= ST_TX_BYTE;
                        end else if (rx_data == 8'h60) begin
                            reply_byte <= latched_spikes[7:0];
                            shift_byte <= latched_spikes[15:8];
                            latched_spikes <= 16'h0000;
                            state <= ST_TX_SPIKE_HI;
                        end else if (rx_data == 8'h70) begin
                            byte_count <= '0;
                            bit_pos <= 3'd0;
                            shift_byte <= 8'h00;
                            state <= ST_SNAP_SAVE_SHIFT;
                        end else if (rx_data == 8'h71) begin
                            byte_count <= '0;
                            bit_pos <= 3'd0;
                            state <= ST_SNAP_LOAD_RX;
                        end else if (rx_data == 8'h72) begin
                            manual_pause <= 1'b1;
                            reply_byte <= 8'h72;
                            state <= ST_TX_BYTE;
                        end else if (rx_data == 8'h73) begin
                            manual_pause <= 1'b0;
                            reply_byte <= 8'h73;
                            state <= ST_TX_BYTE;
                        end else begin
                            reply_byte <= 8'hFF;
                            state <= ST_TX_BYTE;
                        end
                    end
                end

                ST_EVENT_ARG: begin
                    if (rx_valid) begin
                        if (!manual_pause && event_ready[active_net]) begin
                            shared_event_source <= rx_data[ID_W-1:0];
                            shared_event_target_pe <= rx_data[4 +: ID_W];
                            for (int k = 0; k < NETWORK_COUNT; k++) begin
                                if (active_net == NET_W'(k)) begin
                                    event_valid[k] <= 1'b1;
                                    event_broadcast[k] <= pending_broadcast;
                                end
                            end
                            reply_byte <= pending_broadcast ? 8'h31 : 8'h30;
                        end else begin
                            reply_byte <= 8'hFE;
                        end
                        state <= ST_TX_BYTE;
                    end
                end

                ST_TX_SPIKE_HI: begin
                    if (tx_ready) begin
                        reply_byte <= shift_byte;
                        state <= ST_TX_BYTE;
                    end
                end

                ST_TX_BYTE: begin
                    if (tx_ready)
                        state <= ST_IDLE;
                end

                ST_SNAP_SAVE_SHIFT: begin
                    if (snapshot_ready) begin
                        shift_byte <= {snapshot_read_data, shift_byte[7:1]};
                        if (bit_pos == 3'd7) begin
                            bit_pos <= 3'd0;
                            state <= ST_SNAP_SAVE_TX;
                        end else begin
                            bit_pos <= bit_pos + 3'd1;
                        end
                    end
                end

                ST_SNAP_SAVE_TX: begin
                    if (tx_ready) begin
                        if (byte_count == BYTE_CNT_W'(SNAPSHOT_BYTES - 1)) begin
                            state <= ST_IDLE;
                        end else begin
                            byte_count <= byte_count + 1'b1;
                            bit_pos <= 3'd0;
                            state <= ST_SNAP_SAVE_SHIFT;
                        end
                    end
                end

                ST_SNAP_LOAD_RX: begin
                    if (rx_valid) begin
                        shift_byte <= rx_data;
                        bit_pos <= 3'd0;
                        state <= ST_SNAP_LOAD_SHIFT;
                    end
                end

                ST_SNAP_LOAD_SHIFT: begin
                    if (snapshot_ready) begin
                        shift_byte <= {1'b0, shift_byte[7:1]};
                        if (bit_pos == 3'd7) begin
                            bit_pos <= 3'd0;
                            if (byte_count == BYTE_CNT_W'(SNAPSHOT_BYTES - 1)) begin
                                latched_spikes <= 16'h0000;
                                reply_byte <= 8'h71;
                                state <= ST_TX_BYTE;
                            end else begin
                                byte_count <= byte_count + 1'b1;
                                state <= ST_SNAP_LOAD_RX;
                            end
                        end else begin
                            bit_pos <= bit_pos + 3'd1;
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule
