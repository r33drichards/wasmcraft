import org.squiddev.cobalt.*;
import org.squiddev.cobalt.compiler.LoadState;
import org.squiddev.cobalt.function.LuaFunction;
import org.squiddev.cobalt.lib.Bit32Lib;
import org.squiddev.cobalt.lib.system.SystemLibraries;

import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Paths;

/**
 * Minimal standalone runner for the Cobalt Lua VM (the engine CC:Tweaked uses).
 *
 * Usage: java CobaltRunner <script.lua> [args...]
 *
 * Installs the standard system globals (base/string/table/math/io/os/package/utf8/coroutine)
 * plus bit32 (which CC:Tweaked also provides, but CoreLibraries does not auto-install), then
 * compiles and runs the script, forwarding any trailing args to it as `...`.
 */
public final class CobaltRunner {
	public static void main(String[] args) throws Exception {
		if (args.length < 1) {
			System.err.println("usage: CobaltRunner <script.lua> [args...]");
			System.exit(2);
		}

		LuaState state = new LuaState();
		LuaTable globals = SystemLibraries.standardGlobals(state);
		Bit32Lib.add(state, globals);

		String scriptPath = args[0];
		byte[] script = Files.readAllBytes(Paths.get(scriptPath));

		LuaValue[] sargs = new LuaValue[Math.max(0, args.length - 1)];
		for (int i = 1; i < args.length; i++) sargs[i - 1] = ValueFactory.valueOf(args[i]);
		Varargs va = ValueFactory.varargsOf(sargs);

		try {
			LuaFunction fn = LoadState.load(state, new ByteArrayInputStream(script),
				ValueFactory.valueOf("@" + scriptPath), globals);
			LuaThread.runMain(state, fn, va);
		} catch (LuaError e) {
			System.out.flush();
			e.fillTraceback(state);
			System.err.println("lua error: " + e.getMessage());
			System.exit(1);
		}
	}
}
