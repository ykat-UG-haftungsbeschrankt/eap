`timescale 1ns/1ps

module tb_eap16_tangnano9k_top #(
    parameter int N = 16,
    parameter int EVENT_FIFO_DEPTH = 64,
    parameter int WEIGHT_W = 8,
    parameter int IDLE_W = 8
);
    localparam int UART_CLOCK_HZ = 1_000_000;
    localparam int UART_BAUD_RATE = 62_500;
    localparam int UART_CLKS_PER_BIT = 16;
    localparam logic [3:0] TRAIN_SOURCE = 4'd0;
    localparam logic [3:0] TRAIN_PE = 4'(N - 1);

    logic sys_clk = 1'b0;
    logic sys_rst_n = 1'b0;
    logic uart_rx = 1'b1;
    logic uart_tx;
    logic [5:0] led;
    logic [7:0] monitor_data;
    logic monitor_valid;
    logic monitor_framing_error;
    logic [7:0] received_bytes [0:511];
    integer received_count = 0;
    integer expected_index = 0;

    always #5 sys_clk = ~sys_clk;

    eap16_tangnano9k_top #(
        .N(N),
        .EVENT_FIFO_DEPTH(EVENT_FIFO_DEPTH),
        .HEARTBEAT_DIV(8),
        .UART_CLOCK_HZ(UART_CLOCK_HZ),
        .UART_BAUD_RATE(UART_BAUD_RATE),
        .WEIGHT_W(WEIGHT_W),
        .IDLE_W(IDLE_W)
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
        integer bit_position;
        begin
            @(negedge dut.eap_clk);
            uart_rx = 1'b0;
            repeat (UART_CLKS_PER_BIT) @(negedge dut.eap_clk);
            for (bit_position = 0; bit_position < 8; bit_position = bit_position + 1) begin
                uart_rx = value[bit_position];
                repeat (UART_CLKS_PER_BIT) @(negedge dut.eap_clk);
            end
            uart_rx = 1'b1;
            repeat (UART_CLKS_PER_BIT) @(negedge dut.eap_clk);
        end
    endtask

    task automatic expect_text(input string expected);
        integer start_index;
        integer char_index;
        begin
            start_index = expected_index;
            for (char_index = 0; char_index < expected.len(); char_index = char_index + 1) begin
                wait (received_count > start_index + char_index);
                if (received_bytes[start_index + char_index] !== expected[char_index])
                    $fatal(1, "UART reply mismatch at byte %0d: expected %02x, got %02x",
                           start_index + char_index, expected[char_index],
                           received_bytes[start_index + char_index]);
            end
            expected_index = start_index + expected.len();
        end
    endtask

    task automatic expect_crlf;
        begin
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

    task automatic expect_byte(input logic [7:0] expected);
        begin
            wait (received_count > expected_index);
            if (received_bytes[expected_index] !== expected)
                $fatal(1, "UART byte mismatch at byte %0d", expected_index);
            expected_index = expected_index + 1;
        end
    endtask

    task automatic expect_line(input string expected);
        begin
            expect_text(expected);
            expect_crlf();
        end
    endtask

    function automatic logic [7:0] decimal_tens(input logic [3:0] value);
        decimal_tens = (value >= 4'd10) ? 8'h31 : 8'h30;
    endfunction

    function automatic logic [7:0] decimal_ones(input logic [3:0] value);
        if (value >= 4'd10)
            decimal_ones = 8'h30 + (value - 4'd10);
        else
            decimal_ones = 8'h30 + value;
    endfunction

    task automatic expect_event_ack(input logic [3:0] source);
        begin
            expect_text("OK EVENT ");
            expect_byte(decimal_tens(source));
            expect_byte(decimal_ones(source));
            expect_crlf();
        end
    endtask

    task automatic expect_teacher_ack(input logic [3:0] pe);
        begin
            expect_text("OK TEACH ");
            expect_byte(decimal_tens(pe));
            expect_byte(decimal_ones(pe));
            expect_crlf();
        end
    endtask

    task automatic expect_read_header(input logic [3:0] pe);
        begin
            expect_text("PE ");
            expect_byte(decimal_tens(pe));
            expect_byte(decimal_ones(pe));
            expect_text(" COUNT 01 SPIKE 0");
            expect_crlf();
        end
    endtask

    task automatic send_event(input logic [3:0] source);
        begin
            send_uart_byte(8'h45);
            send_uart_byte(8'h56);
            send_uart_byte(8'h45);
            send_uart_byte(8'h4e);
            send_uart_byte(8'h54);
            send_uart_byte(8'h20);
            send_uart_byte((source >= 4'd10) ? 8'h31 : 8'h30);
            send_uart_byte(8'h30 + ((source >= 4'd10) ? source - 4'd10 : source));
            send_uart_byte(8'h0d);
            send_uart_byte(8'h0a);
        end
    endtask

    task automatic send_teacher(input logic [3:0] pe);
        begin
            send_uart_byte(8'h54);
            send_uart_byte(8'h45);
            send_uart_byte(8'h41);
            send_uart_byte(8'h43);
            send_uart_byte(8'h48);
            send_uart_byte(8'h20);
            send_uart_byte((pe >= 4'd10) ? 8'h31 : 8'h30);
            send_uart_byte(8'h30 + ((pe >= 4'd10) ? pe - 4'd10 : pe));
            send_uart_byte(8'h0d);
            send_uart_byte(8'h0a);
        end
    endtask

    task automatic send_read(input logic [3:0] pe);
        begin
            send_uart_byte(8'h52);
            send_uart_byte(8'h45);
            send_uart_byte(8'h41);
            send_uart_byte(8'h44);
            send_uart_byte(8'h20);
            send_uart_byte((pe >= 4'd10) ? 8'h31 : 8'h30);
            send_uart_byte(8'h30 + ((pe >= 4'd10) ? pe - 4'd10 : pe));
            send_uart_byte(8'h0d);
            send_uart_byte(8'h0a);
        end
    endtask

    initial begin
        repeat (2) @(posedge sys_clk);
        @(negedge sys_clk);
        sys_rst_n = 1'b1;
        wait (dut.eap_rst == 1'b0);

        send_uart_byte(8'h48);
        send_uart_byte(8'h45);
        send_uart_byte(8'h4c);
        send_uart_byte(8'h50);
        send_uart_byte(8'h0d);
        send_uart_byte(8'h0a);
        expect_line("EVENT nn | TEACH nn | TICK | READ nn");

        repeat (8) begin
            send_event(TRAIN_SOURCE);
            expect_event_ack(TRAIN_SOURCE);
        end

        send_teacher(TRAIN_PE);
        expect_teacher_ack(TRAIN_PE);
        repeat (4) @(posedge dut.eap_clk);
        if (dut.selected_connection_count !== 5'd1)
            $fatal(1, "UART training did not form source 3 -> PE 7");

        send_read(TRAIN_PE);
        expect_read_header(TRAIN_PE);
        if (led[1] !== 1'b0 || led[2] !== 1'b0)
            $fatal(1, "active-low connection LEDs did not show one connection");

        send_uart_byte(8'h54);
        send_uart_byte(8'h49);
        send_uart_byte(8'h43);
        send_uart_byte(8'h4b);
        send_uart_byte(8'h0d);
        send_uart_byte(8'h0a);
        expect_line("OK TICK");
        send_teacher(TRAIN_PE);
        expect_teacher_ack(TRAIN_PE);
        send_read(TRAIN_PE);
        expect_read_header(TRAIN_PE);

        send_uart_byte(8'h45);
        send_uart_byte(8'h56);
        send_uart_byte(8'h45);
        send_uart_byte(8'h4e);
        send_uart_byte(8'h54);
        send_uart_byte(8'h20);
        send_uart_byte(8'h31);
        send_uart_byte(8'h36);
        send_uart_byte(8'h0d);
        send_uart_byte(8'h0a);
        expect_line("ERR ARG");

        send_uart_byte(8'h54);
        send_uart_byte(8'h49);
        send_uart_byte(8'h43);
        send_uart_byte(8'h4b);
        send_uart_byte(8'h0d);
        send_uart_byte(8'h0a);
        send_uart_byte(8'h54);
        send_uart_byte(8'h49);
        send_uart_byte(8'h43);
        send_uart_byte(8'h4b);
        send_uart_byte(8'h0d);
        send_uart_byte(8'h0a);
        expect_line("OK TICK");
        expect_line("ERR BUSY");

        $display("PASS: UART help, training, readback, maintenance, validation, and busy handling");
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "UART command test timed out");
    end
endmodule
