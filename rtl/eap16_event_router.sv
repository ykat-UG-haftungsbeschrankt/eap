module eap16_event_router #(
    parameter int N = 16,
    parameter int FIFO_DEPTH = 64
) (
    input  logic clk,
    input  logic rst,
    input  logic external_valid,
    input  logic [$clog2(N)-1:0] external_source,
    output logic external_ready,
    input  logic [N-1:0] feedback_spikes,
    output logic event_valid,
    output logic [$clog2(N)-1:0] event_source,
    input  logic event_consume,
    output logic overflow,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] level
);
    localparam int ID_W = $clog2(N);
    localparam int LEVEL_W = $clog2(FIFO_DEPTH + 1);
    localparam int PTR_W = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
    localparam int PENDING_W = $clog2(FIFO_DEPTH + 1);
    localparam int ARBITER_PORTS = N + 1;
    localparam int ARBITER_W =
        (ARBITER_PORTS > 1) ? $clog2(ARBITER_PORTS) : 1;
    localparam logic [PENDING_W-1:0] PENDING_MAX = PENDING_W'(FIFO_DEPTH);

    logic [ID_W-1:0] event_mem [0:FIFO_DEPTH-1];
    logic [PENDING_W-1:0] pending_spikes [0:N-1];
    logic [N:0] arbiter_requests;
    logic [N:0] arbiter_grant;
    logic [N-1:0] spike_grant;
    logic [ID_W-1:0] fifo_write_data;
    logic [LEVEL_W-1:0] fifo_count;
    logic [LEVEL_W-1:0] next_fifo_count;
    logic [PTR_W-1:0] fifo_read_pointer;
    logic [PTR_W-1:0] fifo_write_pointer;
    logic [ARBITER_W-1:0] last_grant;
    logic [ARBITER_W-1:0] selected_port;
    logic fifo_pop;
    logic fifo_push;
    logic fifo_can_push;
    logic external_push;
    logic any_feedback_pending;
    logic selected_valid;
    integer candidate;

    function automatic logic [PTR_W-1:0] increment_pointer(
        input logic [PTR_W-1:0] pointer
    );
        if (pointer == PTR_W'(FIFO_DEPTH - 1))
            increment_pointer = '0;
        else
            increment_pointer = pointer + 1'b1;
    endfunction

    always_comb begin
        event_valid = (fifo_count != '0);
        event_source = event_mem[fifo_read_pointer];
        level = fifo_count;
        fifo_pop = event_valid && event_consume;
        fifo_can_push = (fifo_count < LEVEL_W'(FIFO_DEPTH)) || fifo_pop;

        // Port 0 is the external input; ports 1..N are feedback source IDs.
        arbiter_requests = '0;
        arbiter_requests[0] = external_valid;
        any_feedback_pending = 1'b0;
        for (int i = 0; i < N; i++) begin
            arbiter_requests[i+1] = (pending_spikes[i] != '0);
            any_feedback_pending =
                any_feedback_pending || (pending_spikes[i] != '0);
        end

        arbiter_grant = '0;
        selected_port = '0;
        selected_valid = 1'b0;
        candidate = 0;
        // Select the first pending request after the previous grant.
        for (int offset = 1; offset <= ARBITER_PORTS; offset++) begin
            candidate = last_grant;
            candidate = candidate + offset;
            if (candidate >= ARBITER_PORTS)
                candidate = candidate - ARBITER_PORTS;
            if (!selected_valid && arbiter_requests[candidate]) begin
                arbiter_grant[candidate] = 1'b1;
                selected_port = ARBITER_W'(candidate);
                selected_valid = 1'b1;
            end
        end

        spike_grant = '0;
        for (int i = 0; i < N; i++)
            spike_grant[i] = fifo_can_push && arbiter_grant[i+1];

        external_ready = fifo_can_push &&
                         (arbiter_grant[0] || !any_feedback_pending);
        external_push = external_valid && external_ready &&
                        arbiter_grant[0];
        fifo_push = external_push || (|spike_grant);
        fifo_write_data = external_source;
        for (int i = 0; i < N; i++) begin
            if (spike_grant[i])
                fifo_write_data = ID_W'(i);
        end

        next_fifo_count = fifo_count - LEVEL_W'(fifo_pop) +
                          LEVEL_W'(fifo_push);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            fifo_read_pointer <= '0;
            fifo_write_pointer <= '0;
            fifo_count <= '0;
            last_grant <= ARBITER_W'(ARBITER_PORTS - 1);
            overflow <= 1'b0;
            for (int i = 0; i < N; i++)
                pending_spikes[i] <= '0;
        end else begin
            if (fifo_pop)
                fifo_read_pointer <= increment_pointer(fifo_read_pointer);
            if (fifo_push) begin
                event_mem[fifo_write_pointer] <= fifo_write_data;
                fifo_write_pointer <= increment_pointer(fifo_write_pointer);
                last_grant <= selected_port;
            end
            fifo_count <= next_fifo_count;

            for (int i = 0; i < N; i++) begin
                case ({feedback_spikes[i], spike_grant[i]})
                    2'b10: begin
                        if (pending_spikes[i] != PENDING_MAX)
                            pending_spikes[i] <= pending_spikes[i] + 1'b1;
                        else
                            overflow <= 1'b1;
                    end
                    2'b01:
                        pending_spikes[i] <= pending_spikes[i] - 1'b1;
                    default: begin
                    end
                endcase
            end
        end
    end
endmodule
