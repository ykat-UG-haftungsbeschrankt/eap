`timescale 1ns/1ps

module tb_bit_sequence_cache_eviction;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic sequence_start = 1'b0;
    logic bit_valid = 1'b0;
    logic observed_bit = 1'b0;
    logic next_bit_valid;
    logic next_bit_prediction;

    always #5 clk = ~clk;

    bit_sequence_learner #(
        .HISTORY_BITS(2),
        .CACHE_ENTRIES(2)
    ) dut (
        .clk(clk),
        .rst(rst),
        .sequence_start(sequence_start),
        .bit_valid(bit_valid),
        .observed_bit(observed_bit),
        .next_bit_valid(next_bit_valid),
        .next_bit_prediction(next_bit_prediction)
    );

    task automatic send_bit(
        input logic start,
        input logic value,
        input logic expected_valid,
        input logic expected_prediction
    );
        begin
            @(negedge clk);
            sequence_start = start;
            bit_valid = 1'b1;
            observed_bit = value;
            #1;
            if (next_bit_valid !== expected_valid ||
                next_bit_prediction !== expected_prediction)
                $fatal(1, "cache prediction mismatch before bit %b", value);
            @(posedge clk);
            #1;
            sequence_start = 1'b0;
            bit_valid = 1'b0;
        end
    endtask

    task automatic train_context(
        input logic [1:0] context_bits,
        input logic successor
    );
        begin
            send_bit(1'b1, context_bits[1], 1'b0, 1'b0);
            send_bit(1'b0, context_bits[0], 1'b0, 1'b0);
            send_bit(1'b0, successor, 1'b0, 1'b0);
        end
    endtask

    task automatic check_context(
        input logic [1:0] context_bits,
        input logic successor,
        input logic expected_valid,
        input logic expected_prediction
    );
        begin
            send_bit(1'b1, context_bits[1], 1'b0, 1'b0);
            send_bit(1'b0, context_bits[0], 1'b0, 1'b0);
            send_bit(1'b0, successor,
                     expected_valid, expected_prediction);
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        train_context(2'b00, 1'b1);
        train_context(2'b01, 1'b0);
        train_context(2'b10, 1'b1);

        check_context(2'b01, 1'b0, 1'b1, 1'b0);
        check_context(2'b00, 1'b1, 1'b0, 1'b0);
        check_context(2'b10, 1'b1, 1'b1, 1'b1);
        check_context(2'b01, 1'b0, 1'b0, 1'b0);
        check_context(2'b00, 1'b1, 1'b1, 1'b1);

        $display("PASS: fixed-capacity cache and round-robin eviction");
        $finish;
    end
endmodule
