cmake_minimum_required(VERSION 3.15)
find_package(bouffalo_sdk REQUIRED HINTS $ENV{BL_SDK_BASE})
get_filename_component(FORMAL_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../src" ABSOLUTE)
sdk_add_include_directories(${FORMAL_SOURCE_DIR})
sdk_add_compile_definitions(S9_RUNTIME=1)
target_sources(app PRIVATE
    ${FORMAL_SOURCE_DIR}/s9_protocol.c
    ${FORMAL_SOURCE_DIR}/s9_ble_queue.c
    ${FORMAL_SOURCE_DIR}/s9_gatt.c
    ${FORMAL_SOURCE_DIR}/s9_router.c
    ${FORMAL_SOURCE_DIR}/s9_score_check.c
    ${FORMAL_SOURCE_DIR}/s9_storage.c
    ${FORMAL_SOURCE_DIR}/s9_bus_service.c
    ${FORMAL_SOURCE_DIR}/s9_tasks_bus.c
    ${FORMAL_SOURCE_DIR}/s9_player.c
    ${FORMAL_SOURCE_DIR}/s9_runtime.c
    ${FORMAL_SOURCE_DIR}/sd_spi.c
    ${FORMAL_SOURCE_DIR}/score_service.c
    ${FORMAL_SOURCE_DIR}/bl616_hal.c
    ${FORMAL_SOURCE_DIR}/board_overlay.c
    ${FORMAL_SOURCE_DIR}/ff.c)
# Complete Stage9 candidate entry, with explicit unqualified-board startup gate.
sdk_set_main_file(${FORMAL_SOURCE_DIR}/main.c)

# Real formal media runtime; no --undefined, probe, or synthetic startup.
sdk_add_compile_definitions(S10_MEDIA_RUNTIME=1 S10_PROFILE_HOST_OBSERVER=1 SBC_DEC_INCLUDED)
# BT host/HCI RX threads above the 1 ms polling tasks (default configMAX_PRIORITIES-4 = 3);
# they only run when packets arrive. HCI TX stays at 4 (< RX as the host requires).
sdk_add_compile_definitions(CONFIG_BT_RX_PRIO=5)
sdk_add_include_directories("C:/Users/Haobai/Documents/Codex/s7deps/sdk/components/wireless/bluetooth/blestack/src/include/bluetooth")
target_sources(app PRIVATE
    ${FORMAL_SOURCE_DIR}/s10_codec.c
    ${FORMAL_SOURCE_DIR}/s10_fir.c
    ${FORMAL_SOURCE_DIR}/s10_fir_coeffs.c
    ${FORMAL_SOURCE_DIR}/s10_fir_coeffs16.c
    ${FORMAL_SOURCE_DIR}/s10_pcm_tx.c
    ${FORMAL_SOURCE_DIR}/s10_sd_admission.c
    ${FORMAL_SOURCE_DIR}/s10_spi_dma.c
    ${FORMAL_SOURCE_DIR}/s10_media_pipeline.c
    ${FORMAL_SOURCE_DIR}/s10_profile.c
    ${FORMAL_SOURCE_DIR}/s10_runtime.c
    ${FORMAL_SOURCE_DIR}/ingress_core.c
    ${FORMAL_SOURCE_DIR}/profile_context.c
)
sdk_add_link_options(-Wl,--cref)
target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/s11_storage.c ${FORMAL_SOURCE_DIR}/s11_service.c)
target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/fw_header_overlay.c)
sdk_add_compile_definitions(INSTRUMENT_NEO_SECOND_STAGE=1)
# Board linker template plus the A2DP decode/resample hot path in tcm_text (RAM).
sdk_set_linker_script_macro(${CMAKE_CURRENT_LIST_DIR}/bl616_common_a2dp.ld.in)
project(instrument_neo_r59)

# Restore the complete combo BLE/Classic/SD/FPGA application; local fixes only.
get_target_property(console_sources app SOURCES)
list(FILTER console_sources EXCLUDE REGEX "usb_console[.]c$")
set_property(TARGET app PROPERTY SOURCES ${console_sources})
target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/usb_console_neo.c
 ${FORMAL_SOURCE_DIR}/neo_pds_boot.c ${FORMAL_SOURCE_DIR}/clock_fix.c
 ${FORMAL_SOURCE_DIR}/diag_uart.c ${FORMAL_SOURCE_DIR}/neo_fault_capture.c)
sdk_add_link_options(-Wl,--wrap=btble_assert_err -Wl,--wrap=exception_entry -Wl,--wrap=__assert_func)

target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/link_diag.c)

target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/link_startup.c)

target_sources(app PRIVATE
 ${FORMAL_SOURCE_DIR}/live_loop_core.c
 ${FORMAL_SOURCE_DIR}/shared_raw.c
 ${FORMAL_SOURCE_DIR}/shared_loop.c
 ${FORMAL_SOURCE_DIR}/live_loop_runtime.c)

target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/shared_score.c ${FORMAL_SOURCE_DIR}/loop_evr.c)

target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/ensemble.c)

sdk_add_compile_definitions(INSTRUMENT_AUDIO_HZ=128000u INSTRUMENT_SYS_HZ=40000000u RECORD_PCM_HZ=48000u)

# Candidate rates: external SPI signal integrity still needs board verification.
sdk_add_compile_definitions(FPGA_SPI_HZ=10000000u RECORD_SD_SPI_HZ=40000000u RECORD_FIFO_PROOF=0)


sdk_add_compile_definitions(ENSEMBLE_CAPTURE_DIAG=1)

target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/wire_probe.c)

target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/record_trace.c)
target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/sd_wait_disabled.c)




target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/crc32_shared.c)
# Candidate-local source selection; never modify the installed SDK files.
get_target_property(crc_sources libutils SOURCES)
list(FILTER crc_sources EXCLUDE REGEX "utils_crc[.]c$")
set_property(TARGET libutils PROPERTY SOURCES ${crc_sources})


# Share ABI-preserving RISC-V prologue/epilogue helpers only in file/control
# tasks; leave SPI, DMA, USB and interrupt code compilation unchanged.
set_source_files_properties(${FORMAL_SOURCE_DIR}/s9_runtime.c ${FORMAL_SOURCE_DIR}/s11_storage.c
 ${FORMAL_SOURCE_DIR}/ff.c ${FORMAL_SOURCE_DIR}/shared_loop.c
 ${FORMAL_SOURCE_DIR}/live_loop_core.c ${FORMAL_SOURCE_DIR}/ensemble.c
 ${FORMAL_SOURCE_DIR}/s9_router.c ${FORMAL_SOURCE_DIR}/s9_protocol.c
 ${FORMAL_SOURCE_DIR}/s9_player.c ${FORMAL_SOURCE_DIR}/shared_score.c
 ${FORMAL_SOURCE_DIR}/loop_evr.c ${FORMAL_SOURCE_DIR}/shared_raw.c
 ${FORMAL_SOURCE_DIR}/live_loop_runtime.c ${FORMAL_SOURCE_DIR}/s9_storage.c
 PROPERTIES COMPILE_OPTIONS "-msave-restore")

target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/bus_fault.c ${FORMAL_SOURCE_DIR}/bounded_spi_io.c)

sdk_add_compile_definitions(RECORD_OBSERVER=1)
target_sources(app PRIVATE ${FORMAL_SOURCE_DIR}/record_observer.c)
