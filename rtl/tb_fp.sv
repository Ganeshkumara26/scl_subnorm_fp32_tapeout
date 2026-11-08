`timescale 1ns/1ps
module tb_fp;
    parameter NV = 20000;
    logic clk=0, rst_n=0, ld=0, sdi=0; logic [1:0] mode=0; wire sdo, done, win, busy;
    subnorm_fp32 dut(.*);
    always #5 clk=~clk;
    integer fd, r, n, errs, i, tmo, maxcyc, cyc0; reg [7:0] op; reg [31:0] a, b, exp, got, rem;
    function isnan(input [31:0] x); isnan = (x[30:23]==8'hFF) && (x[22:0]!=0); endfunction
    task pulse_ld(input [1:0] m); begin mode=m; ld=1; @(negedge clk); ld=0; end endtask
    task wait_win; begin tmo=0; while (!win && tmo<20000) begin @(negedge clk); tmo=tmo+1; end end endtask
    initial begin
        errs=0; n=0; repeat(3) @(posedge clk); rst_n=1; @(negedge clk); maxcyc=0;
        fd=$fopen("vec.txt","r");
        while (!$feof(fd) && n<NV) begin
            r=$fscanf(fd,"%h %h %h %h\n",op,a,b,exp);
            if (r==4) begin
                @(negedge clk); pulse_ld(op[0]?2'd1:2'd0); wait_win;
                for (i=0;i<32;i=i+1) begin @(negedge clk); sdi=a[i]; end
                for (i=0;i<32;i=i+1) begin @(negedge clk); sdi=b[i]; end
                @(negedge clk); sdi=0; cyc0=0;
                tmo=0; while (!done && tmo<40000) begin @(negedge clk); tmo=tmo+1; end
                if (tmo>maxcyc) maxcyc=tmo;
                pulse_ld(2'd3); wait_win;
                for (i=0;i<32;i=i+1) begin @(negedge clk); got[i]=sdo; end
                for (i=0;i<32;i=i+1) begin @(negedge clk); rem[i]=sdo; end
                @(negedge clk);
                n=n+1; if (n%1000==0) $display("progress n=%0d errs=%0d", n, errs);
                if (tmo>=40000 || !((got===exp) || (isnan(got)&&isnan(exp)))) begin
                    errs=errs+1; if (errs<=10) $display("FAIL op=%0d a=%h b=%h exp=%h got=%h tmo=%0d",op,a,b,exp,got,tmo);
                end
            end
        end
        $display("DONE vectors=%0d errors=%0d maxcycles=%0d", n, errs, maxcyc); $finish;
    end
endmodule
