module eap16_uart_console #(
    parameter int UART_CLOCK_HZ = 13_500_000,
    parameter int UART_BAUD_RATE = 115_200
) (
    input  logic clk,
    input  logic rst,
    input  logic uart_rx_pin,
    output logic uart_tx_pin,
    output logic event_valid,
    output logic [3:0] event_source,
    input  logic event_ready,
    output logic [15:0] teacher_spike,
    output logic maintenance_tick,
    input  logic [79:0] packed_connection_counts,
    input  logic [15:0] spikes,
    output logic [3:0] debug_pe,
    output logic [3:0] debug_slot,
    input  logic debug_valid,
    input  logic [3:0] debug_source,
    input  logic signed [7:0] debug_weight,
    input  logic [7:0] debug_idle,
    output logic [3:0] status_pe
);
    localparam int MAX_LINE = 32;

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
        RESP_READ_HEADER,
        RESP_READ_SLOT,
        RESP_READ_END,
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
        ST_TX,
        ST_READ_SCAN
    } state_t;

    state_t state;
    response_t response;
    logic [5:0] response_index;
    logic [3:0] response_arg;
    logic [3:0] read_pe;
    logic [3:0] read_slot;
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
    logic [6:0] parsed_decimal;

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

    function automatic logic [7:0] hex_digit(input logic [3:0] value);
        if (value < 4'd10)
            hex_digit = 8'h30 + value;
        else
            hex_digit = 8'h41 + (value - 4'd10);
    endfunction

    function automatic logic [5:0] response_length(input response_t code);
        case (code)
            RESP_EVENT,
            RESP_TEACH:          response_length = 6'd13;
            RESP_TICK:           response_length = 6'd9;
            RESP_READ_HEADER:    response_length = 6'd24;
            RESP_READ_SLOT:      response_length = 6'd28;
            RESP_READ_END:       response_length = 6'd5;
            RESP_HELP:           response_length = 6'd38;
            RESP_ERROR_SYNTAX:   response_length = 6'd12;
            RESP_ERROR_ARGUMENT: response_length = 6'd9;
            RESP_ERROR_LINE:     response_length = 6'd10;
            RESP_ERROR_BUSY:     response_length = 6'd10;
            RESP_ERROR_UART:     response_length = 6'd10;
            default:             response_length = 6'd0;
        endcase
    endfunction

    function automatic logic [7:0] response_character(
        input response_t code,
        input logic [5:0] index,
        input logic [3:0] argument,
        input logic [3:0] pe,
        input logic [3:0] slot,
        input logic [4:0] count,
        input logic spike_value,
        input logic [3:0] source,
        input logic signed [7:0] weight,
        input logic [7:0] idle
    );
        begin
            response_character = 8'h00;
            case (code)
                RESP_EVENT: begin
                    case (index)
                        0: response_character = 8'h4f;
                        1: response_character = 8'h4b;
                        2: response_character = 8'h20;
                        3: response_character = 8'h45;
                        4: response_character = 8'h56;
                        5: response_character = 8'h45;
                        6: response_character = 8'h4e;
                        7: response_character = 8'h54;
                        8: response_character = 8'h20;
                        9: response_character = decimal_tens4(argument);
                        10: response_character = decimal_ones4(argument);
                        11: response_character = 8'h0d;
                        12: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                RESP_TEACH: begin
                    case (index)
                        0: response_character = 8'h4f;
                        1: response_character = 8'h4b;
                        2: response_character = 8'h20;
                        3: response_character = 8'h54;
                        4: response_character = 8'h45;
                        5: response_character = 8'h41;
                        6: response_character = 8'h43;
                        7: response_character = 8'h48;
                        8: response_character = 8'h20;
                        9: response_character = decimal_tens4(argument);
                        10: response_character = decimal_ones4(argument);
                        11: response_character = 8'h0d;
                        12: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                RESP_TICK: begin
                    case (index)
                        0: response_character = 8'h4f;
                        1: response_character = 8'h4b;
                        2: response_character = 8'h20;
                        3: response_character = 8'h54;
                        4: response_character = 8'h49;
                        5: response_character = 8'h43;
                        6: response_character = 8'h4b;
                        7: response_character = 8'h0d;
                        8: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                RESP_READ_HEADER: begin
                    case (index)
                        0: response_character = 8'h50;
                        1: response_character = 8'h45;
                        2: response_character = 8'h20;
                        3: response_character = decimal_tens4(pe);
                        4: response_character = decimal_ones4(pe);
                        5: response_character = 8'h20;
                        6: response_character = 8'h43;
                        7: response_character = 8'h4f;
                        8: response_character = 8'h55;
                        9: response_character = 8'h4e;
                        10: response_character = 8'h54;
                        11: response_character = 8'h20;
                        12: response_character = decimal_tens5(count);
                        13: response_character = decimal_ones5(count);
                        14: response_character = 8'h20;
                        15: response_character = 8'h53;
                        16: response_character = 8'h50;
                        17: response_character = 8'h49;
                        18: response_character = 8'h4b;
                        19: response_character = 8'h45;
                        20: response_character = 8'h20;
                        21: response_character = spike_value ? 8'h31 : 8'h30;
                        22: response_character = 8'h0d;
                        23: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                RESP_READ_SLOT: begin
                    case (index)
                        0: response_character = 8'h53;
                        1: response_character = 8'h4c;
                        2: response_character = 8'h4f;
                        3: response_character = 8'h54;
                        4: response_character = 8'h20;
                        5: response_character = decimal_tens4(slot);
                        6: response_character = decimal_ones4(slot);
                        7: response_character = 8'h20;
                        8: response_character = 8'h53;
                        9: response_character = 8'h52;
                        10: response_character = 8'h43;
                        11: response_character = 8'h20;
                        12: response_character = decimal_tens4(source);
                        13: response_character = decimal_ones4(source);
                        14: response_character = 8'h20;
                        15: response_character = 8'h57;
                        16: response_character = 8'h20;
                        17: response_character = hex_digit(weight[7:4]);
                        18: response_character = hex_digit(weight[3:0]);
                        19: response_character = 8'h20;
                        20: response_character = 8'h41;
                        21: response_character = 8'h47;
                        22: response_character = 8'h45;
                        23: response_character = 8'h20;
                        24: response_character = hex_digit(idle[7:4]);
                        25: response_character = hex_digit(idle[3:0]);
                        26: response_character = 8'h0d;
                        27: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                RESP_READ_END: begin
                    case (index)
                        0: response_character = 8'h45;
                        1: response_character = 8'h4e;
                        2: response_character = 8'h44;
                        3: response_character = 8'h0d;
                        4: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                RESP_HELP: begin
                    case (index)
                        0: response_character = 8'h45;
                        1: response_character = 8'h56;
                        2: response_character = 8'h45;
                        3: response_character = 8'h4e;
                        4: response_character = 8'h54;
                        5: response_character = 8'h20;
                        6: response_character = 8'h6e;
                        7: response_character = 8'h6e;
                        8: response_character = 8'h20;
                        9: response_character = 8'h7c;
                        10: response_character = 8'h20;
                        11: response_character = 8'h54;
                        12: response_character = 8'h45;
                        13: response_character = 8'h41;
                        14: response_character = 8'h43;
                        15: response_character = 8'h48;
                        16: response_character = 8'h20;
                        17: response_character = 8'h6e;
                        18: response_character = 8'h6e;
                        19: response_character = 8'h20;
                        20: response_character = 8'h7c;
                        21: response_character = 8'h20;
                        22: response_character = 8'h54;
                        23: response_character = 8'h49;
                        24: response_character = 8'h43;
                        25: response_character = 8'h4b;
                        26: response_character = 8'h20;
                        27: response_character = 8'h7c;
                        28: response_character = 8'h20;
                        29: response_character = 8'h52;
                        30: response_character = 8'h45;
                        31: response_character = 8'h41;
                        32: response_character = 8'h44;
                        33: response_character = 8'h20;
                        34: response_character = 8'h6e;
                        35: response_character = 8'h6e;
                        36: response_character = 8'h0d;
                        37: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                RESP_ERROR_SYNTAX: begin
                    case (index)
                        0: response_character = 8'h45;
                        1: response_character = 8'h52;
                        2: response_character = 8'h52;
                        3: response_character = 8'h20;
                        4: response_character = 8'h53;
                        5: response_character = 8'h59;
                        6: response_character = 8'h4e;
                        7: response_character = 8'h54;
                        8: response_character = 8'h41;
                        9: response_character = 8'h58;
                        10: response_character = 8'h0d;
                        11: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                RESP_ERROR_ARGUMENT: begin
                    case (index)
                        0: response_character = 8'h45;
                        1: response_character = 8'h52;
                        2: response_character = 8'h52;
                        3: response_character = 8'h20;
                        4: response_character = 8'h41;
                        5: response_character = 8'h52;
                        6: response_character = 8'h47;
                        7: response_character = 8'h0d;
                        8: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                RESP_ERROR_BUSY: begin
                    case (index)
                        0: response_character = 8'h45;
                        1: response_character = 8'h52;
                        2: response_character = 8'h52;
                        3: response_character = 8'h20;
                        4: response_character = 8'h42;
                        5: response_character = 8'h55;
                        6: response_character = 8'h53;
                        7: response_character = 8'h59;
                        8: response_character = 8'h0d;
                        9: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                RESP_ERROR_LINE: begin
                    case (index)
                        0: response_character = 8'h45;
                        1: response_character = 8'h52;
                        2: response_character = 8'h52;
                        3: response_character = 8'h20;
                        4: response_character = 8'h4c;
                        5: response_character = 8'h49;
                        6: response_character = 8'h4e;
                        7: response_character = 8'h45;
                        8: response_character = 8'h0d;
                        9: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                RESP_ERROR_UART: begin
                    case (index)
                        0: response_character = 8'h45;
                        1: response_character = 8'h52;
                        2: response_character = 8'h52;
                        3: response_character = 8'h20;
                        4: response_character = 8'h55;
                        5: response_character = 8'h41;
                        6: response_character = 8'h52;
                        7: response_character = 8'h54;
                        8: response_character = 8'h0d;
                        9: response_character = 8'h0a;
                        default: response_character = 8'h00;
                    endcase
                end
                default: response_character = 8'h00;
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
        debug_pe = read_pe;
        debug_slot = read_slot;
        tx_valid = (state == ST_TX);
        tx_data = response_character(
            response,
            response_index,
        response_arg,
            read_pe,
            read_slot,
            read_count,
            read_spike,
            debug_source,
            debug_weight,
            debug_idle
        );
    end

    always_comb begin
        decoded_command = CMD_INVALID;
        decode_error = RESP_ERROR_SYNTAX;
        decoded_arg = '0;
        parsed_decimal = '0;

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
            if (is_digit(line_buffer[6]) &&
                (line_length == 6'd7 || is_digit(line_buffer[7]))) begin
                parsed_decimal = (line_length == 6'd7)
                               ? {3'b000, digit_value(line_buffer[6])}
                               : {3'b000, digit_value(line_buffer[6])} * 7'd10 +
                                 digit_value(line_buffer[7]);
                if (parsed_decimal <= 7'd15) begin
                    decoded_command = CMD_EVENT;
                    decoded_arg = parsed_decimal[3:0];
                end else begin
                    decode_error = RESP_ERROR_ARGUMENT;
                end
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
            if (is_digit(line_buffer[6]) &&
                (line_length == 6'd7 || is_digit(line_buffer[7]))) begin
                parsed_decimal = (line_length == 6'd7)
                               ? {3'b000, digit_value(line_buffer[6])}
                               : {3'b000, digit_value(line_buffer[6])} * 7'd10 +
                                 digit_value(line_buffer[7]);
                if (parsed_decimal <= 7'd15) begin
                    decoded_command = CMD_TEACH;
                    decoded_arg = parsed_decimal[3:0];
                end else begin
                    decode_error = RESP_ERROR_ARGUMENT;
                end
            end else begin
                decode_error = RESP_ERROR_ARGUMENT;
            end
        end else if ((line_length == 6'd6 || line_length == 6'd7) &&
                     uppercase(line_buffer[0]) == 8'h52 &&
                     uppercase(line_buffer[1]) == 8'h45 &&
                     uppercase(line_buffer[2]) == 8'h41 &&
                     uppercase(line_buffer[3]) == 8'h44 &&
                     line_buffer[4] == 8'h20) begin
            if (is_digit(line_buffer[5]) &&
                (line_length == 6'd6 || is_digit(line_buffer[6]))) begin
                parsed_decimal = (line_length == 6'd6)
                               ? {3'b000, digit_value(line_buffer[5])}
                               : {3'b000, digit_value(line_buffer[5])} * 7'd10 +
                                 digit_value(line_buffer[6]);
                if (parsed_decimal <= 7'd15) begin
                    decoded_command = CMD_READ;
                    decoded_arg = parsed_decimal[3:0];
                end else begin
                    decode_error = RESP_ERROR_ARGUMENT;
                end
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
            read_pe <= 4'd7;
            read_slot <= '0;
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
            status_pe <= 4'd7;
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
                                event_source <= decoded_arg;
                                event_valid <= 1'b1;
                                state <= ST_WAIT_EVENT;
                            end
                            CMD_TEACH: begin
                                response_arg <= decoded_arg;
                                teacher_spike <= 16'b1 << decoded_arg;
                                status_pe <= decoded_arg;
                                state <= ST_WAIT_TEACH;
                            end
                            CMD_TICK: begin
                                maintenance_tick <= 1'b1;
                                state <= ST_WAIT_TICK;
                            end
                            CMD_READ: begin
                                read_pe <= decoded_arg;
                                read_slot <= '0;
                                status_pe <= decoded_arg;
                                response <= RESP_READ_HEADER;
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
                                case (response)
                                    RESP_READ_HEADER:
                                        state <= ST_READ_SCAN;
                                    RESP_READ_SLOT: begin
                                        if (read_slot == 4'd15) begin
                                            response <= RESP_READ_END;
                                            state <= ST_TX;
                                        end else begin
                                            read_slot <= read_slot + 1'b1;
                                            state <= ST_READ_SCAN;
                                        end
                                    end
                                    RESP_READ_END:
                                        state <= ST_COLLECT;
                                    default:
                                        state <= ST_COLLECT;
                                endcase
                            end else begin
                                response_index <= response_index + 1'b1;
                            end
                        end
                    end
                    ST_READ_SCAN: begin
                        if (debug_valid) begin
                            response <= RESP_READ_SLOT;
                            response_index <= '0;
                            state <= ST_TX;
                        end else if (read_slot == 4'd15) begin
                            response <= RESP_READ_END;
                            response_index <= '0;
                            state <= ST_TX;
                        end else begin
                            read_slot <= read_slot + 1'b1;
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
