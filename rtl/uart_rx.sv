module uart_rx #(
    parameter int CLOCK_HZ = 13_500_000,
    parameter int BAUD_RATE = 115_200
) (
    input  logic clk,
    input  logic rst,
    input  logic rx_pin,
    output logic [7:0] rx_data,
    output logic rx_valid,
    output logic framing_error
);
    localparam int CLKS_PER_BIT = (CLOCK_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam int HALF_BIT = (CLKS_PER_BIT > 1) ? CLKS_PER_BIT / 2 : 1;
    localparam int COUNT_W = (CLKS_PER_BIT > 1) ? $clog2(CLKS_PER_BIT) : 1;

    typedef enum logic [1:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_t;

    rx_state_t state;
    logic rx_meta;
    logic rx_sync;
    logic [COUNT_W-1:0] baud_count;
    logic [2:0] bit_index;
    logic [7:0] shift_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= RX_IDLE;
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            baud_count <= '0;
            bit_index <= '0;
            shift_data <= '0;
            rx_data <= '0;
            rx_valid <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            rx_meta <= rx_pin;
            rx_sync <= rx_meta;
            rx_valid <= 1'b0;
            framing_error <= 1'b0;

            case (state)
                RX_IDLE: begin
                    baud_count <= '0;
                    if (!rx_sync)
                        state <= RX_START;
                end
                RX_START: begin
                    if (baud_count == COUNT_W'(HALF_BIT - 1)) begin
                        baud_count <= '0;
                        if (!rx_sync) begin
                            bit_index <= '0;
                            state <= RX_DATA;
                        end else begin
                            state <= RX_IDLE;
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end
                RX_DATA: begin
                    if (baud_count == COUNT_W'(CLKS_PER_BIT - 1)) begin
                        baud_count <= '0;
                        shift_data[bit_index] <= rx_sync;
                        if (bit_index == 3'd7)
                            state <= RX_STOP;
                        else
                            bit_index <= bit_index + 1'b1;
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end
                RX_STOP: begin
                    if (baud_count == COUNT_W'(CLKS_PER_BIT - 1)) begin
                        baud_count <= '0;
                        state <= RX_IDLE;
                        if (rx_sync) begin
                            rx_data <= shift_data;
                            rx_valid <= 1'b1;
                        end else begin
                            framing_error <= 1'b1;
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end
                default: begin
                    state <= RX_IDLE;
                    baud_count <= '0;
                end
            endcase
        end
    end
endmodule
