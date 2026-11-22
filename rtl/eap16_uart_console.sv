/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

module eap16_uart_console #(
    parameter int N = 16,
    parameter int UART_CLOCK_HZ = 13_500_000,
    parameter int UART_BAUD_RATE = 115_200
) (
    input  logic clk,
    input  logic rst,
    input  logic uart_rx_pin,
    output logic uart_tx_pin,
    output logic event_valid,
    output logic [$clog2(N)-1:0] event_source,
    input  logic event_ready,
    output logic [N-1:0] teacher_spike,
    output logic maintenance_tick,
    input  logic [N*5-1:0] packed_connection_counts,
    input  logic [N-1:0] spikes,
    output logic [3:0] status_pe
);
    localparam int MAX_LINE = 32;
    localparam int MAX_REPLY = 38;
    localparam int ID_W = $clog2(N);

    localparam logic [8*13-1:0] TEXT_EVENT =
        {"OK EVENT 00", 8'h0d, 8'h0a};
    localparam logic [8*13-1:0] TEXT_TEACH =
        {"OK TEACH 00", 8'h0d, 8'h0a};
    localparam logic [8*9-1:0] TEXT_TICK =
        {"OK TICK", 8'h0d, 8'h0a};
    localparam logic [8*24-1:0] TEXT_READ =
        {"PE 00 COUNT 00 SPIKE 0", 8'h0d, 8'h0a};
    localparam logic [8*38-1:0] TEXT_HELP =
        {"EVENT nn | TEACH nn | TICK | READ nn", 8'h0d, 8'h0a};
    localparam logic [8*12-1:0] TEXT_SYNTAX =
        {"ERR SYNTAX", 8'h0d, 8'h0a};
    localparam logic [8*9-1:0] TEXT_ARGUMENT =
        {"ERR ARG", 8'h0d, 8'h0a};
    localparam logic [8*10-1:0] TEXT_LINE =
        {"ERR LINE", 8'h0d, 8'h0a};
    localparam logic [8*10-1:0] TEXT_BUSY =
        {"ERR BUSY", 8'h0d, 8'h0a};
    localparam logic [8*10-1:0] TEXT_UART =
        {"ERR UART", 8'h0d, 8'h0a};

    typedef enum logic [2:0] {
        CMD_INVALID,
        CMD_EVENT,
        CMD_TEACH,
        CMD_TICK,
        CMD_READ,
        CMD_HELP
    } command_t;

    typedef enum logic [3:0] {
        RESP_EVENT,
        RESP_TEACH,
        RESP_TICK,
        RESP_READ,
        RESP_HELP,
        RESP_ERROR_SYNTAX,
        RESP_ERROR_ARGUMENT,
        RESP_ERROR_LINE,
        RESP_ERROR_BUSY,
        RESP_ERROR_UART
    } response_t;

    typedef enum logic [2:0] {
        ST_COLLECT,
        ST_EXECUTE,
        ST_WAIT_EVENT,
        ST_WAIT_TEACH,
        ST_WAIT_TICK,
        ST_TX
    } state_t;

    state_t state;
    response_t response;
    logic [5:0] response_index;
    logic [3:0] response_arg;
    logic [3:0] read_pe;
    logic [4:0] read_count;
    logic read_spike;

    logic [7:0] line_buffer [0:MAX_LINE-1];
    logic [5:0] line_length;
    logic line_overflow;
    logic line_uart_error;
    logic discard_until_eol;
    logic swallow_lf;
    logic busy_error_pending;

    logic [7:0] rx_data;
    logic rx_valid;
    logic rx_framing_error;
    logic [7:0] tx_data;
    logic tx_valid;
    logic tx_ready;

    command_t decoded_command;
    response_t decode_error;
    logic [3:0] decoded_arg;
    logic [4:0] parsed_id;

    function automatic logic [7:0] uppercase(input logic [7:0] value);
        if (value >= 8'h61 && value <= 8'h7a)
            uppercase = value - 8'd32;
        else
            uppercase = value;
    endfunction

    function automatic logic is_digit(input logic [7:0] value);
        is_digit = value >= 8'h30 && value <= 8'h39;
    endfunction

    function automatic logic [3:0] digit_value(input logic [7:0] value);
        digit_value = value - 8'h30;
    endfunction

    function automatic logic is_line_end(input logic [7:0] value);
        is_line_end = value == 8'h0a || value == 8'h0d;
    endfunction

    function automatic logic [4:0] parse_id(
        input logic [7:0] first_digit,
        input logic [7:0] second_digit,
        input logic two_digits
    );
        logic [6:0] value;
        begin
            parse_id = '0;
            value = '0;
            if (is_digit(first_digit) &&
                (!two_digits || is_digit(second_digit))) begin
                value = digit_value(first_digit);
                if (two_digits)
                    value = value * 7'd10 + digit_value(second_digit);
                if (value <= 7'd15)
                    parse_id = {1'b1, value[3:0]};
            end
        end
    endfunction

    function automatic logic [7:0] decimal_tens4(input logic [3:0] value);
        decimal_tens4 = (value >= 4'd10) ? 8'h31 : 8'h30;
    endfunction

    function automatic logic [7:0] decimal_ones4(input logic [3:0] value);
        if (value >= 4'd10)
            decimal_ones4 = 8'h30 + (value - 4'd10);
        else
            decimal_ones4 = 8'h30 + value;
    endfunction

    function automatic logic [7:0] decimal_tens5(input logic [4:0] value);
        decimal_tens5 = (value >= 5'd10) ? 8'h31 : 8'h30;
    endfunction

    function automatic logic [7:0] decimal_ones5(input logic [4:0] value);
        if (value >= 5'd10)
            decimal_ones5 = 8'h30 + (value - 5'd10);
        else
            decimal_ones5 = 8'h30 + value;
    endfunction

    function automatic logic [5:0] response_length(input response_t code);
        case (code)
            RESP_EVENT,
            RESP_TEACH:          response_length = 6'd13;
            RESP_TICK:           response_length = 6'd9;
            RESP_READ:           response_length = 6'd24;
            RESP_HELP:           response_length = 6'd38;
            RESP_ERROR_SYNTAX:   response_length = 6'd12;
            RESP_ERROR_ARGUMENT: response_length = 6'd9;
            RESP_ERROR_LINE:     response_length = 6'd10;
            RESP_ERROR_BUSY:     response_length = 6'd10;
            RESP_ERROR_UART:     response_length = 6'd10;
            default:             response_length = 6'd0;
        endcase
    endfunction

    function automatic logic [7:0] packed_text_byte(
        input logic [8*MAX_REPLY-1:0] text,
        input logic [5:0] length,
        input logic [5:0] index
    );
        if (length != 0 && index < length)
            packed_text_byte = text[(length - index)*8 - 1 -: 8];
        else
            packed_text_byte = 8'h00;
    endfunction

    function automatic logic [7:0] response_character(
        input response_t code,
        input logic [5:0] index,
        input logic [3:0] argument,
        input logic [3:0] pe,
        input logic [4:0] count,
        input logic spike_value
    );
        logic [8*MAX_REPLY-1:0] text;
        logic [5:0] length;
        begin
            text = '0;
            length = '0;
            case (code)
                RESP_EVENT: begin
                    text = TEXT_EVENT;
                    length = 6'd13;
                end
                RESP_TEACH: begin
                    text = TEXT_TEACH;
                    length = 6'd13;
                end
                RESP_TICK: begin
                    text = TEXT_TICK;
                    length = 6'd9;
                end
                RESP_READ: begin
                    text = TEXT_READ;
                    length = 6'd24;
                end
                RESP_HELP: begin
                    text = TEXT_HELP;
                    length = 6'd38;
                end
                RESP_ERROR_SYNTAX: begin
                    text = TEXT_SYNTAX;
                    length = 6'd12;
                end
                RESP_ERROR_ARGUMENT: begin
                    text = TEXT_ARGUMENT;
                    length = 6'd9;
                end
                RESP_ERROR_LINE: begin
                    text = TEXT_LINE;
                    length = 6'd10;
                end
                RESP_ERROR_BUSY: begin
                    text = TEXT_BUSY;
                    length = 6'd10;
                end
                RESP_ERROR_UART: begin
                    text = TEXT_UART;
                    length = 6'd10;
                end
                default: begin
                    text = '0;
                    length = '0;
                end
            endcase

            response_character = packed_text_byte(text, length, index);
            case (code)
                RESP_EVENT: begin
                    if (index == 6'd9)
                        response_character = decimal_tens4(argument);
                    else if (index == 6'd10)
                        response_character = decimal_ones4(argument);
                end
                RESP_TEACH: begin
                    if (index == 6'd9)
                        response_character = decimal_tens4(argument);
                    else if (index == 6'd10)
                        response_character = decimal_ones4(argument);
                end
                RESP_READ: begin
                    if (index == 6'd3)
                        response_character = decimal_tens4(pe);
                    else if (index == 6'd4)
                        response_character = decimal_ones4(pe);
                    else if (index == 6'd12)
                        response_character = decimal_tens5(count);
                    else if (index == 6'd13)
                        response_character = decimal_ones5(count);
                    else if (index == 6'd21)
                        response_character = spike_value ? 8'h31 : 8'h30;
                end
                default: begin
                end
            endcase
        end
    endfunction

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

    always_comb begin
        read_count = packed_connection_counts[read_pe*5 +: 5];
        read_spike = spikes[read_pe];
        tx_valid = (state == ST_TX);
        tx_data = response_character(
            response,
            response_index,
            response_arg,
            read_pe,
            read_count,
            read_spike
        );
    end

    always_comb begin
        decoded_command = CMD_INVALID;
        decode_error = RESP_ERROR_SYNTAX;
        decoded_arg = '0;
        parsed_id = '0;

        if (line_uart_error) begin
            decode_error = RESP_ERROR_UART;
        end else if (line_overflow) begin
            decode_error = RESP_ERROR_LINE;
        end else if (line_length == 6'd4 &&
                     uppercase(line_buffer[0]) == 8'h54 &&
                     uppercase(line_buffer[1]) == 8'h49 &&
                     uppercase(line_buffer[2]) == 8'h43 &&
                     uppercase(line_buffer[3]) == 8'h4b) begin
            decoded_command = CMD_TICK;
        end else if (line_length == 6'd4 &&
                     uppercase(line_buffer[0]) == 8'h48 &&
                     uppercase(line_buffer[1]) == 8'h45 &&
                     uppercase(line_buffer[2]) == 8'h4c &&
                     uppercase(line_buffer[3]) == 8'h50) begin
            decoded_command = CMD_HELP;
        end else if ((line_length == 6'd7 || line_length == 6'd8) &&
                     uppercase(line_buffer[0]) == 8'h45 &&
                     uppercase(line_buffer[1]) == 8'h56 &&
                     uppercase(line_buffer[2]) == 8'h45 &&
                     uppercase(line_buffer[3]) == 8'h4e &&
                     uppercase(line_buffer[4]) == 8'h54 &&
                     line_buffer[5] == 8'h20) begin
            parsed_id = parse_id(line_buffer[6], line_buffer[7],
                                 line_length == 6'd8);
            if (parsed_id[4] && parsed_id[3:0] < N) begin
                decoded_command = CMD_EVENT;
                decoded_arg = parsed_id[3:0];
            end else begin
                decode_error = RESP_ERROR_ARGUMENT;
            end
        end else if ((line_length == 6'd7 || line_length == 6'd8) &&
                     uppercase(line_buffer[0]) == 8'h54 &&
                     uppercase(line_buffer[1]) == 8'h45 &&
                     uppercase(line_buffer[2]) == 8'h41 &&
                     uppercase(line_buffer[3]) == 8'h43 &&
                     uppercase(line_buffer[4]) == 8'h48 &&
                     line_buffer[5] == 8'h20) begin
            parsed_id = parse_id(line_buffer[6], line_buffer[7],
                                 line_length == 6'd8);
            if (parsed_id[4] && parsed_id[3:0] < N) begin
                decoded_command = CMD_TEACH;
                decoded_arg = parsed_id[3:0];
            end else begin
                decode_error = RESP_ERROR_ARGUMENT;
            end
        end else if ((line_length == 6'd6 || line_length == 6'd7) &&
                     uppercase(line_buffer[0]) == 8'h52 &&
                     uppercase(line_buffer[1]) == 8'h45 &&
                     uppercase(line_buffer[2]) == 8'h41 &&
                     uppercase(line_buffer[3]) == 8'h44 &&
                     line_buffer[4] == 8'h20) begin
            parsed_id = parse_id(line_buffer[5], line_buffer[6],
                                 line_length == 6'd7);
            if (parsed_id[4] && parsed_id[3:0] < N) begin
                decoded_command = CMD_READ;
                decoded_arg = parsed_id[3:0];
            end else begin
                decode_error = RESP_ERROR_ARGUMENT;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= ST_COLLECT;
            response <= RESP_ERROR_SYNTAX;
            response_index <= '0;
            response_arg <= '0;
            read_pe <= '0;
            line_length <= '0;
            line_overflow <= 1'b0;
            line_uart_error <= 1'b0;
            discard_until_eol <= 1'b0;
            swallow_lf <= 1'b0;
            busy_error_pending <= 1'b0;
            event_valid <= 1'b0;
            event_source <= '0;
            teacher_spike <= '0;
            maintenance_tick <= 1'b0;
            status_pe <= '0;
            for (int i = 0; i < MAX_LINE; i++)
                line_buffer[i] <= '0;
        end else begin
            event_valid <= 1'b0;
            teacher_spike <= '0;
            maintenance_tick <= 1'b0;

            if (state == ST_COLLECT && busy_error_pending) begin
                busy_error_pending <= 1'b0;
                line_length <= '0;
                line_overflow <= 1'b0;
                line_uart_error <= 1'b0;
                response <= RESP_ERROR_BUSY;
                response_index <= '0;
                state <= ST_TX;
            end else begin
                if (rx_framing_error) begin
                    if (state == ST_COLLECT) begin
                        line_uart_error <= 1'b1;
                        line_overflow <= 1'b1;
                    end else begin
                        busy_error_pending <= 1'b1;
                    end
                end

                if (rx_valid) begin
                    if (swallow_lf && rx_data == 8'h0a) begin
                        swallow_lf <= 1'b0;
                    end else begin
                        if (swallow_lf)
                            swallow_lf <= 1'b0;

                        if (state == ST_COLLECT) begin
                            if (discard_until_eol) begin
                                if (is_line_end(rx_data)) begin
                                    discard_until_eol <= 1'b0;
                                    busy_error_pending <= 1'b1;
                                    if (rx_data == 8'h0d)
                                        swallow_lf <= 1'b1;
                                end
                            end else if (is_line_end(rx_data)) begin
                                if (line_length != 0 || line_overflow ||
                                    line_uart_error) begin
                                    state <= ST_EXECUTE;
                                end
                                if (rx_data == 8'h0d)
                                    swallow_lf <= 1'b1;
                            end else if (!line_overflow && !line_uart_error) begin
                                if (line_length < MAX_LINE) begin
                                    line_buffer[line_length] <= rx_data;
                                    line_length <= line_length + 1'b1;
                                end else begin
                                    line_overflow <= 1'b1;
                                end
                            end
                        end else begin
                            if (discard_until_eol) begin
                                if (is_line_end(rx_data)) begin
                                    discard_until_eol <= 1'b0;
                                    busy_error_pending <= 1'b1;
                                    if (rx_data == 8'h0d)
                                        swallow_lf <= 1'b1;
                                end
                            end else if (is_line_end(rx_data)) begin
                                busy_error_pending <= 1'b1;
                                if (rx_data == 8'h0d)
                                    swallow_lf <= 1'b1;
                            end else begin
                                discard_until_eol <= 1'b1;
                            end
                        end
                    end
                end

                case (state)
                    ST_COLLECT: begin
                    end
                    ST_EXECUTE: begin
                        line_length <= '0;
                        line_overflow <= 1'b0;
                        line_uart_error <= 1'b0;
                        case (decoded_command)
                            CMD_EVENT: begin
                                response_arg <= decoded_arg;
                                event_source <= ID_W'(decoded_arg);
                                event_valid <= 1'b1;
                                state <= ST_WAIT_EVENT;
                            end
                            CMD_TEACH: begin
                                response_arg <= decoded_arg;
                                teacher_spike <= N'(1) << decoded_arg;
                                status_pe <= decoded_arg;
                                state <= ST_WAIT_TEACH;
                            end
                            CMD_TICK: begin
                                maintenance_tick <= 1'b1;
                                state <= ST_WAIT_TICK;
                            end
                            CMD_READ: begin
                                read_pe <= decoded_arg;
                                status_pe <= decoded_arg;
                                response <= RESP_READ;
                                response_index <= '0;
                                state <= ST_TX;
                            end
                            CMD_HELP: begin
                                response <= RESP_HELP;
                                response_index <= '0;
                                state <= ST_TX;
                            end
                            default: begin
                                response <= decode_error;
                                response_index <= '0;
                                state <= ST_TX;
                            end
                        endcase
                    end
                    ST_WAIT_EVENT: begin
                        if (event_ready) begin
                            event_valid <= 1'b0;
                            response <= RESP_EVENT;
                            response_index <= '0;
                            state <= ST_TX;
                        end else begin
                            event_valid <= 1'b1;
                        end
                    end
                    ST_WAIT_TEACH: begin
                        response <= RESP_TEACH;
                        response_index <= '0;
                        state <= ST_TX;
                    end
                    ST_WAIT_TICK: begin
                        response <= RESP_TICK;
                        response_index <= '0;
                        state <= ST_TX;
                    end
                    ST_TX: begin
                        if (tx_ready) begin
                            if (response_index + 1'b1 >= response_length(response)) begin
                                response_index <= '0;
                                state <= ST_COLLECT;
                            end else begin
                                response_index <= response_index + 1'b1;
                            end
                        end
                    end
                    default: begin
                        state <= ST_COLLECT;
                    end
                endcase
            end
        end
    end
endmodule
