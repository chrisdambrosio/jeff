# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
mix test                     # Run all tests
mix test test/path/file.exs  # Run a single test file
mix test test/path/file.exs:42  # Run a single test by line number
mix format                   # Auto-format code
mix format --check-formatted # Check formatting (used in CI)
mix credo                    # Run code quality checks
mix dialyzer                 # Run static type analysis
mix docs                     # Generate documentation
```

## Architecture

Jeff is an Elixir library implementing the Open Supervised Device Protocol (OSDP), an access control communications standard for RS-485 serial communication between an Access Control Unit (ACU) and Peripheral Devices (PDs).

### Process Model

The main supervision tree:
- **`Jeff`** — public API, wraps `ACU` GenServer calls
- **`ACU`** — central GenServer orchestrating the polling loop, secure channel establishment, and command/reply state machine
- **`Transport`** — uses the `Connection` behaviour to manage UART serial port via `Circuits.UART`; handles reconnection with backoff
- **`Tracer`** — optional GenServer for packet capture/logging; can be enabled/disabled at runtime

### Core Data Structures

- **`Bus`** — pure data structure (not a process) tracking the device registry, polling cursor, and command queue; lives inside ACU state
- **`Device`** — represents a PD; tracks sequence numbers (0–3), secure channel state, command queue (`:queue`), and online/offline status via timeout
- **`Message`** — encodes/decodes OSDP wire frames (SOM=0x53, address, length, control, data, CRC/checksum)
- **`Command`** / **`Reply`** — define all OSDP command codes and reply types; specialized sub-modules (e.g., `Command.LedSettings`, `Reply.CardData`) handle structured encoding/decoding

### Protocol Flow

1. ACU polls each registered PD in round-robin via the Bus polling cursor
2. Commands from callers are queued on the Device and sent in place of POLL when the cursor reaches that device
3. Replies are matched back to waiting callers; timeouts default to 200ms per OSDP spec
4. **`Framing`** implements `Circuits.UART.Framing` to parse the byte stream into complete OSDP packets before they reach the ACU

### Secure Channel

`SecureChannel` implements AES-128-CBC encryption with a three-state machine: `uninitialized → initialized → established`. It defaults to the OSDP well-known SCBK key. MAC verification is performed on all encrypted messages.

### Error Checking

`ErrorChecks` supports both CRC (via `:cerlc`) and simple checksum modes, selectable per device via `check_scheme: :crc | :checksum`.
