/*
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
 */

`timescale 1ns/1ps

module tb_bit_sequence_benchmark;
    localparam int HISTORY_BITS = 4;
    localparam int ALT_LENGTH = HISTORY_BITS + 32;
    localparam int PERIOD4_LENGTH = HISTORY_BITS + 32;
    localparam int DEBRUIJN_TRAIN_LENGTH = HISTORY_BITS + 128;
    localparam int DEBRUIJN_EVAL_LENGTH = HISTORY_BITS + 64;

    localparam integer PATTERN_ALTERNATING = 0;
    localparam integer PATTERN_0011 = 1;
    localparam integer PATTERN_DEBRUIJN4 = 2;
    localparam logic [15:0] DEBRUIJN4 = 16'b0000100110101111;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic sequence_start = 1'b0;
    logic bit_valid = 1'b0;
    logic observed_bit = 1'b0;
    logic next_bit_valid;
    logic next_bit_prediction;

    integer model_correct;
    integer model_predictions;
    integer zero_baseline_correct;
    integer model_accuracy_tenths;
    integer baseline_accuracy_tenths;

    always #5 clk = ~clk;

    bit_sequence_learner #(
        .HISTORY_BITS(HISTORY_BITS)
    ) dut (
        .clk(clk),
        .rst(rst),
        .sequence_start(sequence_start),
        .bit_valid(bit_valid),
        .observed_bit(observed_bit),
        .next_bit_valid(next_bit_valid),
        .next_bit_prediction(next_bit_prediction)
    );

    function automatic logic pattern_bit(
        input integer pattern,
        input integer position
    );
        case (pattern)
            PATTERN_ALTERNATING:
                pattern_bit = (position % 2) != 0;
            PATTERN_0011:
                pattern_bit = (position % 4) >= 2;
            PATTERN_DEBRUIJN4:
                pattern_bit = DEBRUIJN4[15 - (position % 16)];
            default:
                pattern_bit = 1'b0;
        endcase
    endfunction

    task automatic accept_bit(
        input logic start,
        input logic value,
        input logic score,
        input logic expected_valid
    );
        begin
            @(negedge clk);
            sequence_start = start;
            bit_valid = 1'b1;
            observed_bit = value;
            #1;

            if (score) begin
                if (next_bit_valid !== expected_valid)
                    $fatal(1, "unexpected prediction-valid state");
                if (expected_valid) begin
                    model_predictions = model_predictions + 1;
                    if (next_bit_prediction == value)
                        model_correct = model_correct + 1;
                    if (!value)
                        zero_baseline_correct = zero_baseline_correct + 1;
                end
            end

            @(posedge clk);
            #1;
            sequence_start = 1'b0;
            bit_valid = 1'b0;
        end
    endtask

    task automatic run_pattern(
        input integer pattern,
        input integer length,
        input logic score
    );
        integer position;
        begin
            for (position = 0; position < length; position = position + 1)
                accept_bit(position == 0,
                           pattern_bit(pattern, position),
                           score,
                           position >= HISTORY_BITS);
        end
    endtask

    task automatic reset_model;
        begin
            @(negedge clk);
            rst = 1'b1;
            sequence_start = 1'b0;
            bit_valid = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    task automatic clear_metrics;
        begin
            model_correct = 0;
            model_predictions = 0;
            zero_baseline_correct = 0;
        end
    endtask

    task automatic print_metrics(input string label);
        begin
            model_accuracy_tenths =
                (1000 * model_correct) / model_predictions;
            baseline_accuracy_tenths =
                (1000 * zero_baseline_correct) / model_predictions;
            $display(
                "%0s: learner %0d/%0d (%0d.%0d%%), zero baseline %0d/%0d (%0d.%0d%%)",
                label,
                model_correct, model_predictions,
                model_accuracy_tenths / 10, model_accuracy_tenths % 10,
                zero_baseline_correct, model_predictions,
                baseline_accuracy_tenths / 10,
                baseline_accuracy_tenths % 10
            );
        end
    endtask

    initial begin
        clear_metrics();
        model_accuracy_tenths = 0;
        baseline_accuracy_tenths = 0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        run_pattern(PATTERN_ALTERNATING, ALT_LENGTH, 1'b0);
        run_pattern(PATTERN_ALTERNATING, ALT_LENGTH, 1'b1);
        if (model_predictions != 32 || model_correct != 32 ||
            zero_baseline_correct != 16)
            $fatal(1, "unexpected alternating-pattern benchmark result");
        print_metrics("0101 alternating");

        reset_model();
        clear_metrics();
        run_pattern(PATTERN_0011, PERIOD4_LENGTH, 1'b0);
        run_pattern(PATTERN_0011, PERIOD4_LENGTH, 1'b1);
        if (model_predictions != 32 || model_correct != 32 ||
            zero_baseline_correct != 16)
            $fatal(1, "unexpected 0011-pattern benchmark result");
        print_metrics("0011 period-4");

        reset_model();
        clear_metrics();
        run_pattern(PATTERN_DEBRUIJN4, DEBRUIJN_TRAIN_LENGTH, 1'b0);
        run_pattern(PATTERN_DEBRUIJN4, DEBRUIJN_EVAL_LENGTH, 1'b1);
        if (model_predictions != 64 || model_correct != 64 ||
            zero_baseline_correct != 32)
            $fatal(1, "unexpected order-4 context benchmark result");
        print_metrics("de Bruijn order-4 (all 16 contexts)");

        $display("Benchmark complete: first four sequence bits excluded from scoring.");
        $finish;
    end
endmodule
