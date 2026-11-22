/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module uart_tx #(
    parameter int CLOCK_HZ = 13_500_000,
    parameter int BAUD_RATE = 115_200
) (
    input  logic clk,
    input  logic rst,
    input  logic [7:0] tx_data,
    input  logic tx_valid,
    output logic tx_ready,
    output logic tx_pin
);
    localparam int CLKS_PER_BIT = (CLOCK_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam int COUNT_W = (CLKS_PER_BIT > 1) ? $clog2(CLKS_PER_BIT) : 1;

    typedef enum logic [1:0] {
        TX_IDLE,
        TX_START,
        TX_DATA,
        TX_STOP
    } tx_state_t;

    tx_state_t state;
    logic [COUNT_W-1:0] baud_count;
    logic [2:0] bit_index;
    logic [7:0] shift_data;

    always_comb begin
        tx_ready = (state == TX_IDLE);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= TX_IDLE;
            baud_count <= '0;
            bit_index <= '0;
            shift_data <= '0;
            tx_pin <= 1'b1;
        end else begin
            case (state)
                TX_IDLE: begin
                    baud_count <= '0;
                    tx_pin <= 1'b1;
                    if (tx_valid) begin
                        shift_data <= tx_data;
                        bit_index <= '0;
                        tx_pin <= 1'b0;
                        state <= TX_START;
                    end
                end
                TX_START: begin
                    if (baud_count == COUNT_W'(CLKS_PER_BIT - 1)) begin
                        baud_count <= '0;
                        tx_pin <= shift_data[0];
                        state <= TX_DATA;
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end
                TX_DATA: begin
                    if (baud_count == COUNT_W'(CLKS_PER_BIT - 1)) begin
                        baud_count <= '0;
                        if (bit_index == 3'd7) begin
                            tx_pin <= 1'b1;
                            state <= TX_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                            tx_pin <= shift_data[bit_index + 1'b1];
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end
                TX_STOP: begin
                    if (baud_count == COUNT_W'(CLKS_PER_BIT - 1)) begin
                        baud_count <= '0;
                        tx_pin <= 1'b1;
                        state <= TX_IDLE;
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end
                default: begin
                    state <= TX_IDLE;
                    baud_count <= '0;
                    tx_pin <= 1'b1;
                end
            endcase
        end
    end
endmodule
