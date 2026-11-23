/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module blm_quad_tangnano9k_top #(
    parameter int N = 16,
    parameter int NETWORK_COUNT = 4,
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
    localparam int ID_W = $clog2(N);
    localparam int SYNAPSE_ADDR_W = $clog2(NETWORK_COUNT*N*N);

    logic eap_clk;
    logic eap_rst;
    logic snapshot_pause;
    logic snapshot_shift_enable;
    logic snapshot_write_enable;
    logic snapshot_write_data;
    logic snapshot_read_data;
    logic snapshot_ready;
    logic [NETWORK_COUNT-1:0] learning_enable;
    logic [NETWORK_COUNT-1:0] event_valid;
    logic [NETWORK_COUNT*ID_W-1:0] event_source;
    logic [NETWORK_COUNT*ID_W-1:0] event_target_pe;
    logic [NETWORK_COUNT-1:0] event_broadcast;
    logic [NETWORK_COUNT*N-1:0] teacher_spike;
    logic [NETWORK_COUNT-1:0] maintenance_tick;
    logic [NETWORK_COUNT-1:0] event_ready;
    logic [NETWORK_COUNT*N-1:0] spikes;
    logic [1:0] active_network;
    logic [23:0] heartbeat_counter;
    logic heartbeat;
    logic [5:0] led_status;

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

    blm_uart_bridge #(
        .N(N),
        .NETWORK_COUNT(NETWORK_COUNT),
        .UART_CLOCK_HZ(UART_CLOCK_HZ),
        .UART_BAUD_RATE(UART_BAUD_RATE)
    ) bridge (
        .clk(eap_clk),
        .rst(eap_rst),
        .uart_rx_pin(uart_rx),
        .uart_tx_pin(uart_tx),
        .snapshot_pause(snapshot_pause),
        .snapshot_shift_enable(snapshot_shift_enable),
        .snapshot_write_enable(snapshot_write_enable),
        .snapshot_write_data(snapshot_write_data),
        .snapshot_read_data(snapshot_read_data),
        .snapshot_ready(snapshot_ready),
        .learning_enable(learning_enable),
        .event_valid(event_valid),
        .event_source(event_source),
        .event_target_pe(event_target_pe),
        .event_broadcast(event_broadcast),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .event_ready(event_ready),
        .spikes(spikes),
        .active_network_out(active_network)
    );

    binary_lut_dual_array #(
        .N(N),
        .NETWORK_COUNT(NETWORK_COUNT),
        .SNAPSHOT_ACCESS(1'b1),
        .CONNECTION_COUNTS(1'b0),
        .SYNAPSE_READ_PORT(1'b0)
    ) fabric (
        .clk(eap_clk),
        .rst(eap_rst),
        .snapshot_pause(snapshot_pause),
        .snapshot_shift_enable(snapshot_shift_enable),
        .snapshot_write_enable(snapshot_write_enable),
        .snapshot_write_data(snapshot_write_data),
        .snapshot_read_data(snapshot_read_data),
        .snapshot_ready(snapshot_ready),
        .learning_enable(learning_enable),
        .event_valid(event_valid),
        .event_source(event_source),
        .event_target_pe(event_target_pe),
        .event_broadcast(event_broadcast),
        .selected_pe('0),
        .synapse_read_addr({SYNAPSE_ADDR_W{1'b0}}),
        .synapse_read_data(),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .event_ready(event_ready),
        .spikes(spikes),
        .selected_connection_counts()
    );

    always_ff @(posedge eap_clk) begin
        if (eap_rst) begin
            heartbeat_counter <= '0;
            heartbeat <= 1'b0;
        end else if (HEARTBEAT_DIV <= 1 ||
                     heartbeat_counter == 24'(HEARTBEAT_DIV - 1)) begin
            heartbeat_counter <= '0;
            heartbeat <= ~heartbeat;
        end else begin
            heartbeat_counter <= heartbeat_counter + 1'b1;
        end
    end

    always_ff @(posedge eap_clk) begin
        if (eap_rst)
            led_status <= 6'b111111;
        else
            led_status <= ~{
                (|spikes),
                snapshot_pause,
                learning_enable[active_network],
                active_network,
                heartbeat
            };
    end

    assign led = led_status;
endmodule
