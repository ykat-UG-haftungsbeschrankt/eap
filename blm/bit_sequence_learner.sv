module bit_sequence_learner #(
    parameter int HISTORY_BITS = 4,
    parameter int CACHE_ENTRIES = 32
) (
    input  logic clk,
    input  logic rst,
    input  logic sequence_start,
    input  logic bit_valid,
    input  logic observed_bit,
    output logic next_bit_valid,
    output logic next_bit_prediction
);
    localparam int HISTORY_COUNT_W = $clog2(HISTORY_BITS + 32'd1);
    localparam int CACHE_INDEX_W =
        (CACHE_ENTRIES > 1) ? $clog2(CACHE_ENTRIES) : 1;
    localparam logic [HISTORY_COUNT_W-1:0] HISTORY_COUNT_MAX =
        HISTORY_COUNT_W'(HISTORY_BITS);

    logic [HISTORY_BITS-1:0] history;
    logic [HISTORY_COUNT_W-1:0] history_count;
    logic context_valid [0:CACHE_ENTRIES-1];
    logic [HISTORY_BITS-1:0] context_tag [0:CACHE_ENTRIES-1];
    logic [1:0] successor_counter [0:CACHE_ENTRIES-1];
    logic [CACHE_INDEX_W-1:0] hit_index;
    logic [CACHE_INDEX_W-1:0] free_index;
    logic [CACHE_INDEX_W-1:0] insert_index;
    logic [CACHE_INDEX_W-1:0] replacement_pointer;
    logic cache_hit;
    logic free_found;

    function automatic logic [1:0] update_counter(
        input logic [1:0] counter,
        input logic bit_value
    );
        if (bit_value) begin
            update_counter = (counter == 2'b11)
                           ? 2'b11 : counter + 2'b01;
        end else begin
            update_counter = (counter == 2'b00)
                           ? 2'b00 : counter - 2'b01;
        end
    endfunction

    function automatic logic [CACHE_INDEX_W-1:0] next_cache_index(
        input logic [CACHE_INDEX_W-1:0] index
    );
        if (index == CACHE_INDEX_W'(CACHE_ENTRIES - 32'd1))
            next_cache_index = '0;
        else
            next_cache_index = index + CACHE_INDEX_W'(1);
    endfunction

    always @* begin
        cache_hit = 1'b0;
        hit_index = '0;
        free_found = 1'b0;
        free_index = '0;

        for (int i = 0; i < CACHE_ENTRIES; i++) begin
            if (!cache_hit && context_valid[i] &&
                context_tag[i] == history) begin
                cache_hit = 1'b1;
                hit_index = CACHE_INDEX_W'(i);
            end
            if (!free_found && !context_valid[i]) begin
                free_found = 1'b1;
                free_index = CACHE_INDEX_W'(i);
            end
        end

        insert_index = free_found ? free_index : replacement_pointer;
        next_bit_valid = (history_count == HISTORY_COUNT_MAX) &&
                         cache_hit && !sequence_start && !rst;
        next_bit_prediction = 1'b0;
        if (next_bit_valid)
            next_bit_prediction = successor_counter[hit_index][1];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            history <= '0;
            history_count <= '0;
            replacement_pointer <= '0;
            for (int i = 0; i < CACHE_ENTRIES; i++) begin
                context_valid[i] <= 1'b0;
                context_tag[i] <= '0;
                successor_counter[i] <= 2'b01;
            end
        end else if (sequence_start) begin
            history <= bit_valid ? HISTORY_BITS'(observed_bit) : '0;
            history_count <= bit_valid ? HISTORY_COUNT_W'(1) : '0;
        end else if (bit_valid) begin
            if (history_count == HISTORY_COUNT_MAX) begin
                if (cache_hit) begin
                    successor_counter[hit_index] <=
                        update_counter(successor_counter[hit_index],
                                       observed_bit);
                end else begin
                    context_valid[insert_index] <= 1'b1;
                    context_tag[insert_index] <= history;
                    successor_counter[insert_index] <=
                        update_counter(2'b01, observed_bit);
                    replacement_pointer <= next_cache_index(insert_index);
                end
            end
            history <= (history << 1'b1) | HISTORY_BITS'(observed_bit);
            if (history_count < HISTORY_COUNT_MAX)
                history_count <= history_count + HISTORY_COUNT_W'(1);
        end
    end
endmodule
