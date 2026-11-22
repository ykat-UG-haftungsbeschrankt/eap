/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

`timescale 1ns/1ps

module tb_bit_sequence_learner #(
    parameter int HISTORY_BITS = 4,
    parameter int CACHE_ENTRIES = 32
);
    localparam int TRAIN_LENGTH = HISTORY_BITS + 32;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic sequence_start = 1'b0;
    logic bit_valid = 1'b0;
    logic observed_bit = 1'b0;
    logic next_bit_valid;
    logic next_bit_prediction;

    always #5 clk = ~clk;

    bit_sequence_learner #(
        .HISTORY_BITS(HISTORY_BITS),
        .CACHE_ENTRIES(CACHE_ENTRIES)
    ) dut (
        .clk(clk),
        .rst(rst),
        .sequence_start(sequence_start),
        .bit_valid(bit_valid),
        .observed_bit(observed_bit),
        .next_bit_valid(next_bit_valid),
        .next_bit_prediction(next_bit_prediction)
    );

    function automatic logic period4_bit(input integer position);
        period4_bit = (position % 4) >= 2;
    endfunction

    task automatic send_bit(
        input logic start,
        input logic value,
        input logic check_valid,
        input logic expected_valid,
        input logic check_prediction,
        input logic expected_prediction
    );
        begin
            @(negedge clk);
            sequence_start = start;
            bit_valid = 1'b1;
            observed_bit = value;
            #1;
            if (check_valid && next_bit_valid !== expected_valid)
                $fatal(1, "prediction-valid mismatch before bit %b", value);
            if (check_prediction &&
                next_bit_prediction !== expected_prediction)
                $fatal(1, "prediction mismatch before bit %b", value);
            if (check_valid && !expected_valid &&
                next_bit_prediction !== 1'b0)
                $fatal(1, "invalid prediction output was not zero");

            @(posedge clk);
            #1;
            sequence_start = 1'b0;
            bit_valid = 1'b0;
        end
    endtask

    task automatic check_while_idle(
        input integer cycles,
        input logic expected_valid,
        input logic expected_prediction
    );
        begin
            repeat (cycles) begin
                @(negedge clk);
                sequence_start = 1'b0;
                bit_valid = 1'b0;
                #1;
                if (next_bit_valid !== expected_valid ||
                    next_bit_prediction !== expected_prediction)
                    $fatal(1, "prediction changed while input was idle");
                @(posedge clk);
                #1;
            end
        end
    endtask

    initial begin
        integer position;
        logic value;
        logic expected_valid;

        repeat (2) @(posedge clk);
        #1;
        if (next_bit_valid !== 1'b0 ||
            next_bit_prediction !== 1'b0)
            $fatal(1, "reset state exposed a prediction");

        @(negedge clk);
        rst = 1'b0;

        // A new sequence must not train a transition from the old context.
        for (position = 0; position < HISTORY_BITS; position = position + 1)
            send_bit(position == 0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
        send_bit(1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0);
        for (position = 0; position < HISTORY_BITS; position = position + 1)
            send_bit(position == 0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
        send_bit(1'b0, 1'b1, 1'b1, 1'b0, 1'b1, 1'b0);

        @(negedge clk);
        rst = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        if (next_bit_valid !== 1'b0)
            $fatal(1, "reset did not clear context");
        @(negedge clk);
        rst = 1'b0;

        // Train repeated 0011; the cache learns each recurring context.
        for (position = 0; position < TRAIN_LENGTH; position = position + 1) begin
            value = period4_bit(position);
            send_bit(position == 0, value, 1'b0, 1'b0, 1'b0, 1'b0);
        end

        for (position = 0; position < TRAIN_LENGTH; position = position + 1) begin
            value = period4_bit(position);
            expected_valid = position >= HISTORY_BITS;
            send_bit(position == 0, value, 1'b1, expected_valid,
                     expected_valid, value);
        end
        check_while_idle(3, 1'b1, period4_bit(TRAIN_LENGTH));

        // A start pulse without data clears only history.
        @(negedge clk);
        sequence_start = 1'b1;
        bit_valid = 1'b0;
        #1;
        if (next_bit_valid !== 1'b0)
            $fatal(1, "sequence_start did not invalidate context");
        @(posedge clk);
        #1;
        sequence_start = 1'b0;
        check_while_idle(1, 1'b0, 1'b0);

        for (position = 0; position < HISTORY_BITS; position = position + 1) begin
            value = period4_bit(position);
            send_bit(position == 0, value, 1'b1, 1'b0, 1'b0, 1'b0);
        end
        value = period4_bit(HISTORY_BITS);
        send_bit(1'b0, value, 1'b1, 1'b1, 1'b1, value);

        // Reset clears cached contexts; the first successor is not predicted.
        @(negedge clk);
        rst = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        if (next_bit_valid !== 1'b0 ||
            next_bit_prediction !== 1'b0)
            $fatal(1, "reset did not clear learned state");
        @(negedge clk);
        rst = 1'b0;

        for (position = 0; position < HISTORY_BITS; position = position + 1)
            send_bit(position == 0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
        send_bit(1'b0, 1'b1, 1'b1, 1'b0, 1'b1, 1'b0);

        // The observed successor populated the cache for the next occurrence.
        for (position = 0; position < HISTORY_BITS; position = position + 1)
            send_bit(position == 0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
        send_bit(1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1);

        $display("PASS: HISTORY_BITS=%0d fixed-capacity context cache", HISTORY_BITS);
        $finish;
    end
endmodule
