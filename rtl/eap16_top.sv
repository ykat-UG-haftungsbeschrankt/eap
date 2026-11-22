// EAP-16 integration shell with a shared external/feedback event router.
module eap16_top #(
    parameter int N = 16,
    parameter int FANIN = (N < 16) ? N : 16,
    parameter logic signed [23:0] THRESHOLD = 24'sd1000,
    parameter int WEIGHT_W = 8,
    parameter int IDLE_W = 8,
    parameter int EVENT_FIFO_DEPTH = 64
) (
    input  logic clk,
    input  logic rst,
    input  logic learning_enable,
    input  logic event_valid,
    input  logic [$clog2(N)-1:0] event_source,
    input  logic [N-1:0] teacher_spike,
    input  logic maintenance_tick,
    output logic event_ready,
    output logic event_overflow,
    output logic [N-1:0] spikes,
    output logic [N*5-1:0] packed_connection_counts
);
    localparam int ID_W = $clog2(N);

    logic routed_event_valid;
    logic [ID_W-1:0] routed_event_source;
    logic [$clog2(EVENT_FIFO_DEPTH+1)-1:0] event_fifo_level;

    eap16_event_router #(
        .N(N),
        .FIFO_DEPTH(EVENT_FIFO_DEPTH)
    ) event_router (
        .clk(clk),
        .rst(rst),
        .external_valid(event_valid),
        .external_source(event_source),
        .external_ready(event_ready),
        .feedback_spikes(spikes),
        .event_valid(routed_event_valid),
        .event_source(routed_event_source),
        .event_consume(routed_event_valid),
        .overflow(event_overflow),
        .level(event_fifo_level)
    );

    for (genvar g = 0; g < N; g++) begin : gen_pe
        logic [$clog2(FANIN+1)-1:0] count;
        eap_dynamic_pe #(
            .PE_ID(g),
            .N(N),
            .FANIN(FANIN),
            .THRESHOLD(THRESHOLD),
            .WEIGHT_W(WEIGHT_W),
            .IDLE_W(IDLE_W)
        ) u_pe (
            .clk(clk),
            .rst(rst),
            .learning_enable(learning_enable),
            .event_valid(routed_event_valid),
            .event_source(routed_event_source),
            .teacher_spike(teacher_spike[g]),
            .maintenance_tick(maintenance_tick),
            .spike(spikes[g]),
            .connection_count(count)
        );

        // Five bits cover the configured maximum FANIN of 16.
        assign packed_connection_counts[g*5 +: 5] = 5'(count);
    end
endmodule
