# run_gui.do — compile + simulate with GUI, no quit
# Usage:  do run_gui.do

if {[file exists work]} { vdel -all }
vlib work

vlog -sv riscv_pkg.sv \
        imem.sv dmem.sv prf.sv rat.sv arat.sv free_list.sv \
        bpu.sv decode.sv alu.sv fetch.sv \
        rename_stage.sv rob.sv rs.sv lsq.sv \
        Top.sv \
        tb_Top.sv

vsim work.tb_Top
add wave -r /*
run -all
