`timescale 1ns/1ps

module tb_binary_lut_tangnano9k_top;
    localparam int UART_CLOCK_HZ = 1_000_000;
    localparam int UART_BAUD_RATE = 62_500;
    localparam int UART_CLKS_PER_BIT = 16;

    logic sys_clk = 1'b0;
    logic sys_rst_n = 1'b0;
    logic uart_rx = 1'b1;
    logic uart_tx;
    logic [5:0] led;

    logic [7:0] monitor_data;
    logic monitor_valid;
    logic monitor_framing_error;
    logic [7:0] received_bytes [0:255];
    integer received_count = 0;
    integer expected_index = 0;

    always #5 sys_clk = ~sys_clk;

    blm_binary_lut_tangnano9k_top #(
        .N(16),
        .EVENT_FIFO_DEPTH(64),
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
            received_bytes[received_count] <= monitor_data;
            received_count <= received_count + 1;
        end
        if (monitor_framing_error)
            $fatal(1, "console transmitted an invalid UART stop bit");
    end

    task automatic send_uart_byte(input logic [7:0] value);
        begin
            @(negedge dut.eap_clk);
            uart_rx = 1'b0;
            repeat (UART_CLKS_PER_BIT) @(negedge dut.eap_clk);
            for (int bit_position = 0; bit_position < 8; bit_position++) begin
                uart_rx = value[bit_position];
                repeat (UART_CLKS_PER_BIT) @(negedge dut.eap_clk);
            end
            uart_rx = 1'b1;
            repeat (UART_CLKS_PER_BIT) @(negedge dut.eap_clk);
        end
    endtask

    task automatic send_command(input string command);
        begin
            for (int character = 0; character < command.len(); character++)
                send_uart_byte(command[character]);
            send_uart_byte(8'h0d);
            send_uart_byte(8'h0a);
        end
    endtask

    task automatic expect_text(input string expected);
        integer start_index;
        begin
            start_index = expected_index;
            for (int character = 0; character < expected.len(); character++) begin
                wait (received_count > start_index + character);
                if (received_bytes[start_index + character] !== expected[character])
                    $fatal(1, "UART reply mismatch at byte %0d",
                           start_index + character);
            end
            expected_index = start_index + expected.len();
        end
    endtask

    task automatic expect_line(input string expected);
        begin
            expect_text(expected);
            wait (received_count > expected_index);
            if (received_bytes[expected_index] !== 8'h0d)
                $fatal(1, "UART reply is missing carriage return");
            expected_index = expected_index + 1;
            wait (received_count > expected_index);
            if (received_bytes[expected_index] !== 8'h0a)
                $fatal(1, "UART reply is missing line feed");
            expected_index = expected_index + 1;
        end
    endtask

    initial begin
        repeat (2) @(posedge sys_clk);
        @(negedge sys_clk);
        sys_rst_n = 1'b1;
        wait (dut.eap_rst == 1'b0);

        send_command("HELP");
        expect_line("EVENT nn | TEACH nn | TICK | READ nn");

        send_command("EVENT 00");
        expect_line("OK EVENT 00");
        send_command("TEACH 01");
        expect_line("OK TEACH 01");
        send_command("READ 01");
        expect_line("PE 01 COUNT 01 SPIKE 0");

        send_command("TICK");
        expect_line("OK TICK");
        repeat (3) begin
            send_command("EVENT 00");
            expect_line("OK EVENT 00");
        end
        send_command("READ 01");
        expect_line("PE 01 COUNT 01 SPIKE 0");

        if (dut.network.event_overflow)
            $fatal(1, "unexpected event-router overflow");

        $display("PASS: binary 16-PE UART training, readback, and feedback");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "binary LUT PE board test timed out");
    end
endmodule
