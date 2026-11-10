using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;

namespace FreeObd
{
    public static class Program
    {
        const uint Base = 0x00000000; const int MemSize = 512 * 1024;

        class Rig
        {
            public VirtualEcu Ecu; public VirtualBus Bus; public ReadOnlyClient Client;
            public Rig() { Ecu = new VirtualEcu(MemSize, Base); Bus = new VirtualBus(Ecu); Client = new ReadOnlyClient(new IsoTp(Bus, VirtualEcu.ReqId, VirtualEcu.RespId)); }
        }

        static int passed, failed;
        static void Test(string name, Action t)
        {
            try { t(); passed++; Console.WriteLine("  PASS  " + name); }
            catch (Exception e) { failed++; Console.WriteLine("  FAIL  " + name + "  -> " + e.GetType().Name + ": " + e.Message); }
        }
        static void Assert(bool c, string m) { if (!c) throw new Exception(m); }
        static string Sha(byte[] b) { using (SHA256 s = SHA256.Create()) return BitConverter.ToString(s.ComputeHash(b)).Replace("-", "").ToLowerInvariant(); }
        static T Expect<T>(Action a) where T : Exception
        {
            try { a(); } catch (T e) { return e; }
            throw new Exception("expected " + typeof(T).Name + " but nothing was thrown");
        }
        static DumpResult FullDump(Rig r)
        {
            r.Client.StartSession(); r.Client.Unlock(VirtualEcu.DemoKey);
            return r.Client.DumpAndVerify(Base, MemSize, null);
        }

        static int RunTests()
        {
            Console.WriteLine("FreeOBD core tests (virtual ECU, " + (MemSize / 1024) + " KB image)");

            Test("identifies the ECU", delegate { Rig r = new Rig(); r.Client.StartSession(); Assert(r.Client.ReadText(0xF190) == "FREEOBDVIRT000001", "VIN mismatch"); Assert(r.Client.ReadText(0xF189) == "VIRT-CAL-1.0", "cal id mismatch"); });

            Test("full dump matches ECU memory bit for bit", delegate
            {
                Rig r = new Rig(); DumpResult d = FullDump(r);
                Assert(d.Verified, "two-pass verify failed");
                Assert(Sha(d.Data) == Sha(r.Ecu.Memory), "dump differs from ECU memory");
                Assert(d.Sha256 == Sha(r.Ecu.Memory), "reported hash wrong");
            });

            Test("survives dropped CAN frames (retries)", delegate
            {
                Rig r = new Rig(); r.Bus.RxHook = delegate(int n, CanFrame f) { if (n % 997 == 0) return null; return f; };
                DumpResult d = FullDump(r);
                Assert(d.Verified && Sha(d.Data) == Sha(r.Ecu.Memory), "dump wrong after drops");
                Assert(r.Client.Retries > 0, "no retries happened, hook ineffective");
            });

            Test("survives 'response pending' and 'busy' replies", delegate
            {
                Rig r = new Rig(); r.Ecu.PendingEvery = 50; r.Ecu.BusyEvery = 77;
                DumpResult d = FullDump(r);
                Assert(d.Verified && Sha(d.Data) == Sha(r.Ecu.Memory), "dump wrong");
            });

            Test("catches silent single-bit corruption in a transfer", delegate
            {
                Rig r = new Rig(); int cf = 0;
                r.Bus.RxHook = delegate(int n, CanFrame f)
                {
                    if ((f.Data[0] >> 4) == 2 && ++cf == 1000) { byte[] d = (byte[])f.Data.Clone(); d[1] ^= 0x01; return new CanFrame(f.Id, d); }
                    return f;
                };
                DumpResult res = FullDump(r);
                Assert(!res.Verified, "corruption was NOT detected");
                Assert(res.Mismatches >= 1 && res.FirstMismatch >= 0, "no mismatch reported");
            });

            Test("wrong key is rejected, third failure locks the ECU out", delegate
            {
                Rig r = new Rig(); r.Client.StartSession(); Func<byte[], byte[]> bad = delegate(byte[] s) { return new byte[] { 1, 2, 3, 4 }; };
                Assert(Expect<UdsException>(delegate { r.Client.Unlock(bad); }).Nrc == 0x35, "expected invalid key");
                Assert(Expect<UdsException>(delegate { r.Client.Unlock(bad); }).Nrc == 0x35, "expected invalid key (2)");
                Assert(Expect<UdsException>(delegate { r.Client.Unlock(bad); }).Nrc == 0x36, "expected attempts exceeded");
                Assert(Expect<UdsException>(delegate { r.Client.Unlock(VirtualEcu.DemoKey); }).Nrc == 0x37, "expected locked out even with right key");
            });

            Test("cannot read memory while locked", delegate
            {
                Rig r = new Rig(); r.Client.StartSession();
                Assert(Expect<UdsException>(delegate { r.Client.ReadMemory(Base, 16); }).Nrc == 0x33, "expected security access denied");
            });

            Test("out-of-range read is rejected by the ECU", delegate
            {
                Rig r = new Rig(); r.Client.StartSession(); r.Client.Unlock(VirtualEcu.DemoKey);
                Assert(Expect<UdsException>(delegate { r.Client.ReadMemory(Base + MemSize - 8, 64); }).Nrc == 0x31, "expected out of range");
            });

            Test("read-only guard blocks writes, flash, routines and resets before the bus", delegate
            {
                Rig r = new Rig(); r.Client.StartSession(); r.Client.Unlock(VirtualEcu.DemoKey);
                int tx = r.Bus.TxFrames;
                byte[][] bad = {
                    new byte[] { 0x2E, 0xF1, 0x90, 0x41 },       // write data by id
                    new byte[] { 0x34, 0x00, 0x44, 0, 0, 0, 0, 0, 1, 0 }, // request download
                    new byte[] { 0x36, 0x01, 0xFF },             // transfer data
                    new byte[] { 0x31, 0x01, 0xFF, 0x00 },       // routine control
                    new byte[] { 0x11, 0x01 },                   // ECU reset
                    new byte[] { 0x14, 0xFF, 0xFF, 0xFF },       // clear DTCs
                    new byte[] { 0x10, 0x02 },                   // programming session
                    new byte[] { 0x27, 0x03, 0x00 }              // other security level
                };
                foreach (byte[] b in bad) { byte[] bb = b; Expect<ReadOnlyViolation>(delegate { r.Client.Request(bb); }); }
                Assert(r.Bus.TxFrames == tx, "a blocked request reached the bus");
                Assert(r.Ecu.UnsafeRequestsSeen == 0, "ECU saw an unsafe request");
            });

            Console.WriteLine();
            Console.WriteLine(passed + " passed, " + failed + " failed");
            return failed == 0 ? 0 : 1;
        }

        static int SimDump(string outPath)
        {
            Rig r = new Rig(); r.Client.StartSession(); r.Client.Unlock(VirtualEcu.DemoKey);
            Console.WriteLine("ECU: " + r.Client.ReadText(0xF190) + "  cal " + r.Client.ReadText(0xF189));
            DumpResult d = r.Client.DumpAndVerify(Base, MemSize, delegate(int p) { if (p % (64 * 1024) == 0) Console.WriteLine("  read " + p / 1024 + " KB"); });
            File.WriteAllBytes(outPath, d.Data);
            Console.WriteLine("Verified: " + (d.Verified ? "YES (two independent passes match)" : "NO - " + d.Mismatches + " mismatches, first at 0x" + d.FirstMismatch.ToString("X")));
            Console.WriteLine("SHA-256 : " + d.Sha256);
            Console.WriteLine("Saved   : " + outPath + " (" + d.Data.Length + " bytes), " + r.Client.Log.Count + " messages logged, " + r.Client.Retries + " retries");
            return d.Verified ? 0 : 1;
        }

        public static int Main(string[] args)
        {
            if (args.Length >= 1 && args[0] == "test") return RunTests();
            if (args.Length >= 2 && args[0] == "sim-dump") return SimDump(args[1]);
            Console.WriteLine("FreeObdCore - read-only ECU backup core (virtual ECU stage)");
            Console.WriteLine("  FreeObdCore.exe test");
            Console.WriteLine("  FreeObdCore.exe sim-dump <out.bin>");
            return 0;
        }
    }
}
