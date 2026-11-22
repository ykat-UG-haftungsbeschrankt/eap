/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module blm_binary_lut_tangnano9k_top #(
    parameter int N = 16,
    parameter int EVENT_FIFO_DEPTH = 64,
    parameter int unsigned HEARTBEAT_DIV = 6_750_000,
    parameter int UART_CLOCK_HZ = 13_500_000,
    parameter int UART_BAUD_RATE = 115_200
) (
    input  logic sys_clk,
    input  logic sys_rst_n,
    input  logic uart_rx,
    output logic uart_tx,
    output logic [5:0] led
);
    logic eap_clk;
    logic eap_rst;
    logic event_valid;
    logic [$clog2(N)-1:0] event_source;
    logic event_ready;
    logic event_overflow;
    logic [N-1:0] teacher_spike;
    logic maintenance_tick;
    logic [N-1:0] spikes;
    logic [N*5-1:0] packed_connection_counts;
    logic [4:0] selected_connection_count;
    logic [3:0] status_pe;
    logic [31:0] heartbeat_counter;
    logic heartbeat;
    logic [5:0] led_status;

    assign selected_connection_count =
        packed_connection_counts[status_pe*5 +: 5];

    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            eap_clk <= 1'b0;
            eap_rst <= 1'b1;
        end else begin
            eap_clk <= ~eap_clk;
            if (eap_clk)
                eap_rst <= 1'b0;
        end
    end

    eap16_uart_console #(
        .N(N),
        .UART_CLOCK_HZ(UART_CLOCK_HZ),
        .UART_BAUD_RATE(UART_BAUD_RATE)
    ) console (
        .clk(eap_clk),
        .rst(eap_rst),
        .uart_rx_pin(uart_rx),
        .uart_tx_pin(uart_tx),
        .event_valid(event_valid),
        .event_source(event_source),
        .event_ready(event_ready),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .packed_connection_counts(packed_connection_counts),
        .spikes(spikes),
        .status_pe(status_pe)
    );

    binary_lut_array #(
        .N(N),
        .FIFO_DEPTH(EVENT_FIFO_DEPTH)
    ) network (
        .clk(eap_clk),
        .rst(eap_rst),
        .learning_enable(1'b1),
        .event_valid(event_valid),
        .event_source(event_source),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .event_ready(event_ready),
        .event_overflow(event_overflow),
        .spikes(spikes),
        .packed_connection_counts(packed_connection_counts)
    );

    always_ff @(posedge eap_clk) begin
        if (eap_rst) begin
            heartbeat_counter <= '0;
            heartbeat <= 1'b0;
        end else if (HEARTBEAT_DIV <= 1 ||
                     heartbeat_counter == 32'(HEARTBEAT_DIV - 1)) begin
            heartbeat_counter <= '0;
            heartbeat <= ~heartbeat;
        end else begin
            heartbeat_counter <= heartbeat_counter + 1'b1;
        end
    end

    always_ff @(posedge eap_clk) begin
        if (eap_rst)
            led_status <= 6'b111111;
        else if (event_overflow)
            led_status <= 6'b000000;
        else
            led_status <= ~{selected_connection_count[3:0],
                            (selected_connection_count != 0),
                            heartbeat};
    end

    assign led = led_status;
endmodule
