using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace FreeObd
{
    public class ReadOnlyViolation : Exception { public ReadOnlyViolation(string m) : base(m) { } }

    public class UdsException : Exception
    {
        public byte Sid, Nrc;
        public UdsException(byte sid, byte nrc) : base("ECU rejected service 0x" + sid.ToString("X2") + " with NRC 0x" + nrc.ToString("X2")) { Sid = sid; Nrc = nrc; }
    }

    public class DumpResult
    {
        public byte[] Data;
        public string Sha256;
        public bool Verified;
        public int Mismatches;
        public int FirstMismatch = -1;
    }

    /// <summary>
    /// UDS client that can only READ. Anything that could write, erase, reprogram, reset or
    /// run a routine on the ECU is refused before it reaches the bus.
    /// </summary>
    public class ReadOnlyClient
    {
        // 0x10 session (default/extended only), 0x3E tester present, 0x27 security access (unlock to read),
        // 0x22 read DID, 0x23 read memory, 0x19 read DTCs.
        static readonly HashSet<byte> Allowed = new HashSet<byte> { 0x10, 0x3E, 0x27, 0x22, 0x23, 0x19 };

        readonly IsoTp tp;
        public readonly List<string> Log = new List<string>();
        public int MaxRetries = 3;
        public int Retries;

        public ReadOnlyClient(IsoTp tp) { this.tp = tp; }

        static string Hex(byte[] b) { StringBuilder s = new StringBuilder(); for (int i = 0; i < b.Length && i < 24; i++) s.Append(b[i].ToString("X2")); if (b.Length > 24) s.Append("..(" + b.Length + ")"); return s.ToString(); }

        static void Guard(byte[] req)
        {
            if (req == null || req.Length == 0) throw new ArgumentException("empty request");
            if (!Allowed.Contains(req[0])) throw new ReadOnlyViolation("service 0x" + req[0].ToString("X2") + " is blocked: this client is read-only");
            if (req[0] == 0x10 && (req.Length != 2 || ((req[1] & 0x7F) != 0x01 && (req[1] & 0x7F) != 0x03)))
                throw new ReadOnlyViolation("only default (01) and extended (03) diagnostic sessions are allowed");
            if (req[0] == 0x27 && (req.Length < 2 || req[1] > 2)) throw new ReadOnlyViolation("only seed/key security levels 01/02 are allowed");
        }

        public byte[] Request(byte[] req)
        {
            Guard(req);
            Exception last = null;
            for (int attempt = 0; attempt <= MaxRetries; attempt++)
            {
                if (attempt > 0) Retries++;
                try
                {
                    tp.Send(req); Log.Add("TX " + Hex(req));
                    int pending = 0;
                    while (true)
                    {
                        byte[] r = tp.Receive(); Log.Add("RX " + Hex(r));
                        if (r[0] == 0x7F && r.Length >= 3 && r[1] == req[0])
                        {
                            if (r[2] == 0x78 && pending++ < 10) continue;
                            if (r[2] == 0x21) { last = new UdsException(req[0], r[2]); break; } // busy: retry
                            throw new UdsException(req[0], r[2]);
                        }
                        if (r[0] == (byte)(req[0] + 0x40)) return r;
                    }
                }
                catch (TimeoutException e) { last = e; }
                catch (IOException e) { last = e; }
            }
            throw new IOException("request 0x" + req[0].ToString("X2") + " failed after " + MaxRetries + " retries", last);
        }

        public void StartSession() { Request(new byte[] { 0x10, 0x03 }); }

        public void Unlock(Func<byte[], byte[]> keyFromSeed)
        {
            byte[] r = Request(new byte[] { 0x27, 0x01 });
            byte[] seed = new byte[r.Length - 2]; Array.Copy(r, 2, seed, 0, seed.Length);
            bool zero = true; foreach (byte b in seed) if (b != 0) zero = false;
            if (zero) return; // already unlocked
            byte[] key = keyFromSeed(seed);
            byte[] req = new byte[2 + key.Length]; req[0] = 0x27; req[1] = 0x02; Array.Copy(key, 0, req, 2, key.Length);
            Request(req);
        }

        public string ReadText(ushort did)
        {
            byte[] r = Request(new byte[] { 0x22, (byte)(did >> 8), (byte)did });
            return Encoding.ASCII.GetString(r, 3, r.Length - 3);
        }

        public byte[] ReadMemory(uint addr, int size)
        {
            byte[] req = { 0x23, 0x24, (byte)(addr >> 24), (byte)(addr >> 16), (byte)(addr >> 8), (byte)addr, (byte)(size >> 8), (byte)size };
            byte[] r = Request(req);
            if (r.Length != 1 + size) throw new IOException("short read: wanted " + size + " bytes, got " + (r.Length - 1));
            byte[] d = new byte[size]; Array.Copy(r, 1, d, 0, size); return d;
        }

        byte[] ReadAll(uint start, int length, int block, Action<int> progress)
        {
            byte[] buf = new byte[length]; int pos = 0;
            while (pos < length)
            {
                int n = Math.Min(block, length - pos);
                Array.Copy(ReadMemory((uint)(start + pos), n), 0, buf, pos, n);
                pos += n; if (progress != null) progress(pos);
            }
            return buf;
        }

        /// <summary>
        /// Reads the region twice using different block sizes (so block boundaries differ),
        /// then compares byte for byte. A transfer glitch that corrupts one pass is caught.
        /// </summary>
        public DumpResult DumpAndVerify(uint start, int length, Action<int> progress)
        {
            byte[] a = ReadAll(start, length, 0x100, progress);
            byte[] b = ReadAll(start, length, 0xF3, null);
            DumpResult res = new DumpResult { Data = a };
            for (int i = 0; i < length; i++)
                if (a[i] != b[i]) { res.Mismatches++; if (res.FirstMismatch < 0) res.FirstMismatch = i; }
            res.Verified = res.Mismatches == 0;
            using (SHA256 sha = SHA256.Create())
                res.Sha256 = BitConverter.ToString(sha.ComputeHash(a)).Replace("-", "").ToLowerInvariant();
            return res;
        }
    }
}
