/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

`timescale 1ns/1ps

module tb_binary_lut_quad_tangnano9k_top;
    localparam int N = 16;
    localparam int NETWORK_COUNT = 4;
    localparam int SNAPSHOT_BITS = NETWORK_COUNT * N * (2*(N - 1) + 4);
    localparam int SNAPSHOT_BYTES = (SNAPSHOT_BITS + 7) / 8;
    localparam int UART_CLOCK_HZ = 1_000_000;
    localparam int UART_BAUD_RATE = 125_000;
    localparam int UART_CLKS_PER_BIT = 8;

    logic sys_clk = 1'b0;
    logic sys_rst_n = 1'b0;
    logic uart_rx = 1'b1;
    logic uart_tx;
    logic [5:0] led;

    logic [7:0] monitor_data;
    logic monitor_valid;
    logic monitor_framing_error;
    logic [7:0] rx_queue [0:1023];
    integer rx_write = 0;
    integer rx_read = 0;
    logic [7:0] saved_image [0:SNAPSHOT_BYTES-1];
    logic [7:0] verify_image [0:SNAPSHOT_BYTES-1];

    always #5 sys_clk = ~sys_clk;

    blm_quad_tangnano9k_top #(
        .N(N),
        .NETWORK_COUNT(NETWORK_COUNT),
        .HEARTBEAT_DIV(8),
        .UART_CLOCK_HZ(UART_CLOCK_HZ),
        .UART_BAUD_RATE(UART_BAUD_RATE)
    ) dut (
        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .led(led)
    );

    uart_rx #(
        .CLOCK_HZ(UART_CLOCK_HZ),
        .BAUD_RATE(UART_BAUD_RATE)
    ) response_monitor (
        .clk(dut.eap_clk),
        .rst(dut.eap_rst),
        .rx_pin(uart_tx),
        .rx_data(monitor_data),
        .rx_valid(monitor_valid),
        .framing_error(monitor_framing_error)
    );

    always @(posedge dut.eap_clk) begin
        if (monitor_valid) begin
            rx_queue[rx_write] <= monitor_data;
            rx_write <= rx_write + 1;
        end
        if (monitor_framing_error)
            $fatal(1, "quad UART bridge transmitted an invalid stop bit");
    end

    task automatic send_byte(input logic [7:0] value);
        begin
            @(negedge dut.eap_clk);
            uart_rx = 1'b0;
            repeat (UART_CLKS_PER_BIT) @(negedge dut.eap_clk);
            for (int b = 0; b < 8; b++) begin
                uart_rx = value[b];
                repeat (UART_CLKS_PER_BIT) @(negedge dut.eap_clk);
            end
            uart_rx = 1'b1;
            repeat (UART_CLKS_PER_BIT) @(negedge dut.eap_clk);
        end
    endtask

    task automatic recv_byte(output logic [7:0] value);
        begin
            wait (rx_write > rx_read);
            value = rx_queue[rx_read];
            rx_read = rx_read + 1;
        end
    endtask

    task automatic expect_byte(input logic [7:0] expected);
        logic [7:0] actual;
        begin
            recv_byte(actual);
            if (actual !== expected)
                $fatal(1, "UART reply was 0x%02x, expected 0x%02x",
                       actual, expected);
        end
    endtask

    task automatic read_spikes(output logic [15:0] mask);
        logic [7:0] lo;
        logic [7:0] hi;
        begin
            send_byte(8'h60);
            recv_byte(lo);
            recv_byte(hi);
            mask = {hi, lo};
        end
    endtask

    initial begin
        logic [15:0] spike_mask;
        logic any_nonzero;

        repeat (2) @(posedge sys_clk);
        @(negedge sys_clk);
        sys_rst_n = 1'b1;
        wait (dut.eap_rst == 1'b0);

        // PING
        send_byte(8'h00);
        expect_byte(8'h55);

        // Select network 0, train source 0 -> PE 1
        send_byte(8'h10);
        expect_byte(8'h10);
        send_byte(8'h30);
        send_byte(8'h10); // target PE 1, source 0
        expect_byte(8'h30);
        send_byte(8'h41); // teach PE 1
        expect_byte(8'h41);
        send_byte(8'h50); // maintenance tick clears pre-trace / post_recent
        expect_byte(8'h50);
        read_spikes(spike_mask);
        if (!spike_mask[1])
            $fatal(1, "teacher spike on network 0 PE 1 was not latched");

        // Verify network 3 is isolated (no learned connection on PE 1)
        send_byte(8'h13);
        expect_byte(8'h13);
        repeat (3) begin
            send_byte(8'h30);
            send_byte(8'h10);
            expect_byte(8'h30);
        end
        read_spikes(spike_mask);
        if (spike_mask[1])
            $fatal(1, "network 0 learning leaked into network 3");

        // Select network 3 and train source 2 -> PE 4
        send_byte(8'h30);
        send_byte(8'h42); // target PE 4, source 2
        expect_byte(8'h30);
        send_byte(8'h44); // teach PE 4
        expect_byte(8'h44);
        send_byte(8'h50);
        expect_byte(8'h50);
        read_spikes(spike_mask);
        if (!spike_mask[4])
            $fatal(1, "teacher spike on network 3 PE 4 was not latched");

        // Save complete 272-byte snapshot across all 4 networks over UART
        send_byte(8'h70);
        any_nonzero = 1'b0;
        for (int i = 0; i < SNAPSHOT_BYTES; i++) begin
            recv_byte(saved_image[i]);
            if (saved_image[i] != 8'h00)
                any_nonzero = 1'b1;
        end
        if (!any_nonzero)
            $fatal(1, "saved UART snapshot was all zero");

        // Overwrite entire 4-network state with zeros via SNAPSHOT_LOAD
        send_byte(8'h71);
        for (int i = 0; i < SNAPSHOT_BYTES; i++)
            send_byte(8'h00);
        expect_byte(8'h71);

        // Confirm network 0 PE 1 no longer spikes on 3 source-0 events
        send_byte(8'h10);
        expect_byte(8'h10);
        send_byte(8'h20); // disable learning while probing
        expect_byte(8'h20);
        repeat (3) begin
            send_byte(8'h30);
            send_byte(8'h10);
            expect_byte(8'h30);
        end
        read_spikes(spike_mask);
        if (spike_mask[1])
            $fatal(1, "cleared snapshot still fired on network 0 PE 1");

        // Restore exact 272-byte snapshot over UART
        send_byte(8'h71);
        for (int i = 0; i < SNAPSHOT_BYTES; i++)
            send_byte(saved_image[i]);
        expect_byte(8'h71);

        // Verify byte-exact readback after restore
        send_byte(8'h70);
        for (int i = 0; i < SNAPSHOT_BYTES; i++) begin
            recv_byte(verify_image[i]);
            if (verify_image[i] !== saved_image[i])
                $fatal(1, "UART snapshot mismatch at byte %0d: 0x%02x != 0x%02x",
                       i, verify_image[i], saved_image[i]);
        end

        // Verify restored network 0 PE 1 spikes on 3 source-0 events
        repeat (3) begin
            send_byte(8'h30);
            send_byte(8'h10);
            expect_byte(8'h30);
        end
        read_spikes(spike_mask);
        if (!spike_mask[1])
            $fatal(1, "restored network 0 PE 1 did not fire");

        // Verify restored network 3 PE 4 spikes on 3 source-2 events
        send_byte(8'h13);
        expect_byte(8'h13);
        send_byte(8'h20);
        expect_byte(8'h20);
        repeat (3) begin
            send_byte(8'h30);
            send_byte(8'h42);
            expect_byte(8'h30);
        end
        read_spikes(spike_mask);
        if (!spike_mask[4])
            $fatal(1, "restored network 3 PE 4 did not fire");

        $display("PASS: quad 16-PE UART bridge, 4-network isolation, and %0d-byte snapshot save/restore",
                 SNAPSHOT_BYTES);
        $finish;
    end

    initial begin
        #50_000_000;
        $fatal(1, "quad UART top test timed out");
    end
endmodule
