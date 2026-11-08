# This file generates matches 
import pathlib
parent = str(pathlib.Path(__file__).resolve().parent)


with open(parent + "/GraphemeBreakProperty.txt", "r") as File:
    lines = File.readlines();

Start = []
End = []
with open(parent + "/../table.zig", "r") as File:
    clines = File.readlines();
    for line in clines:
        Start.append(line)
        if "START_EAT" in line:
            break

    for line in clines:
        if "END_EAT" in line:
            End.append(line)
        elif len(End) != 0:
            End.append(line)

with open(parent + "/../table.zig", "w") as File:
    for i in Start: 
        File.write(i)

    File.write("pub const ranges = [_]PropertyRange{\n")
    # Start, End, Property    
    Ranges = []

    for line in lines:
        line = line.rstrip('\n')

        if line != "":
            if line[0] != '#':
                brl = [x for x in line.split(" ") if x != ''];
                if '.' in brl[0]:
                    t = brl[0].split("..")
                    Ranges.append((int(t[0], 16), int(t[1], 16), brl[2]))
                else:
                    Ranges.append((int(brl[0], 16), int(brl[0], 16), brl[2]))
               
    Ranges.sort(key=lambda x: (x[0], x[1]))
    for Range in Ranges:
        File.write(f"   .{{ .start = {Range[0]}, .end = {Range[1]}, .property = .{Range[2]} }},\n");

    File.write("};\n")
    for i in End: File.write(i)
