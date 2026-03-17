#!/usr/bin/env node
"use strict";

// Node.js wrapper for running Debian on V86 emulator
// Usage: node nodejs-debian.js [path-to-debian.iso]
//
// This provides a serial console interface to the Debian VM,
// suitable for headless/SSH deployment on Xbox via Dev Mode.

var fs = require("fs");
var path = require("path");
var V86 = require("./libv86.js").V86;

function readfile(filepath)
{
    return new Uint8Array(fs.readFileSync(filepath)).buffer;
}

// Parse arguments
var isoPath = process.argv[2] || path.join(__dirname, "debian-xbox.iso");
var memoryMB = parseInt(process.argv[3]) || 512;

if (!fs.existsSync(isoPath)) {
    console.error("Error: Disk image not found: " + isoPath);
    console.error("");
    console.error("Usage: node nodejs-debian.js [path-to-image] [memory-mb]");
    console.error("");
    console.error("To create a Debian image, run:");
    console.error("  sudo ../tools/build-debian-iso.sh");
    console.error("  # or");
    console.error("  sudo ../tools/build-debian-img.sh");
    process.exit(1);
}

var bios = readfile(path.join(__dirname, "seabios.bin"));
var image = readfile(isoPath);

process.stdin.setRawMode(true);
process.stdin.resume();
process.stdin.setEncoding("utf8");

console.log("===========================================");
console.log("  Xbox Linux - Debian V86 Emulator");
console.log("===========================================");
console.log("Image: " + isoPath);
console.log("Memory: " + memoryMB + " MB");
console.log("Press Ctrl+C to stop");
console.log("-------------------------------------------");
console.log("Now booting, please stand by ...");
console.log("");

// Detect if image is ISO (CD-ROM) or raw disk (HDA)
var isISO = isoPath.endsWith(".iso");

var config = {
    memory_size: memoryMB * 1024 * 1024,
    bios: { buffer: bios },
    acpi: true,
    autostart: true,
    uart1: true,
};

if (isISO) {
    config.cdrom = { buffer: image };
} else {
    config.hda = { buffer: image, async: true };
}

var emulator = new V86(config);

// Serial console output
emulator.add_listener("serial0-output-byte", function(byte)
{
    var chr = String.fromCharCode(byte);
    process.stdout.write(chr);
});

// Keyboard input
process.stdin.on("data", function(c)
{
    if (c === "\u0003")
    {
        // Ctrl+C
        console.log("\n\nShutting down emulator...");
        emulator.stop();
        process.stdin.pause();
        process.exit(0);
    }
    else
    {
        emulator.serial0_send(c);
    }
});

// Graceful shutdown
process.on("SIGINT", function() {
    emulator.stop();
    process.exit(0);
});

process.on("SIGTERM", function() {
    emulator.stop();
    process.exit(0);
});
