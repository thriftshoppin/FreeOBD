using System;
using System.Collections.Generic;

namespace FreeObd
{
    /// <summary>
    /// A simulated ECU speaking UDS over ISO-TP. It has a deterministic memory image,
    /// session control, seed/key security access with lockout, and ReadMemoryByAddress.
    /// It models protocol behavior only, NOT any real vehicle's algorithm or memory map.
    /// </summary>
    public class VirtualEcu
    {
        public const uint ReqId = 0x7E0, RespId = 0x7E8;
        public readonly byte[] Memory;
        public readonly uint BaseAddress;
        public int Requests, UnsafeRequestsSeen;
        public int PendingEvery;   // if >0, every Nth request first answers "response pending" (0x78)
        public int BusyEvery;      // if >0, every Nth request is rejected busy (0x21) once
        static readonly HashSet<byte> UnsafeSids = new HashSet<byte> { 0x11, 0x14, 0x2E, 0x2F, 0x31, 0x34, 0x35, 0x36, 0x37, 0x3D, 0x85 };

        byte session = 1; bool unlocked; bool lockedOut; int badKeys; byte[] currentSeed;
        readonly Random rng = new Random(1234);
        byte[] rxBuf; int rxLen, rxOff;
        byte[] txBuf; int txOff; byte txSn;

        public VirtualEcu(int memorySize, uint baseAddress)
        {
            BaseAddress = baseAddress;
            Memory = new byte[memorySize];
            new Random(42).NextBytes(Memory);
        }

        /// <summary>Demo seed-to-key function. A real ECU driver supplies its own.</summary>
        public static byte[] DemoKey(byte[] seed)
        {
            uint s = (uint)((seed[0] << 24) | (seed[1] << 16) | (seed[2] << 8) | seed[3]);
            s ^= 0xA5C3F00D; s = (s << 7) | (s >> 25); s += 0x1234;
            return new byte[] { (byte)(s >> 24), (byte)(s >> 16), (byte)(s >> 8), (byte)s };
        }

        public List<CanFrame> OnFrame(CanFrame f)
        {
            List<CanFrame> o = new List<CanFrame>();
            if (f.Id != ReqId) return o;
            int t = f.Data[0] >> 4;
            if (t == 0)
            {
                int n = f.Data[0] & 0xF; byte[] p = new byte[n]; Array.Copy(f.Data, 1, p, 0, n);
                txBuf = null; Handle(p, o);
            }
            else if (t == 1)
            {
                txBuf = null;
                rxLen = ((f.Data[0] & 0xF) << 8) | f.Data[1]; rxBuf = new byte[rxLen];
                Array.Copy(f.Data, 2, rxBuf, 0, 6); rxOff = 6;
                o.Add(new CanFrame(RespId, new byte[] { 0x30, 0, 0, 0, 0, 0, 0, 0 }));
            }
            else if (t == 2)
            {
                if (rxBuf == null) return o;
                int n = Math.Min(7, rxLen - rxOff); Array.Copy(f.Data, 1, rxBuf, rxOff, n); rxOff += n;
                if (rxOff >= rxLen) { byte[] p = rxBuf; rxBuf = null; Handle(p, o); }
            }
            else if (t == 3 && txBuf != null)
            {
                while (txOff < txBuf.Length)
                {
                    int n = Math.Min(7, txBuf.Length - txOff);
                    byte[] cf = new byte[8]; cf[0] = (byte)(0x20 | txSn); Array.Copy(txBuf, txOff, cf, 1, n);
                    o.Add(new CanFrame(RespId, cf)); txOff += n; txSn = (byte)((txSn + 1) & 0xF);
                }
                txBuf = null;
            }
            return o;
        }

        void Respond(List<CanFrame> o, byte[] p)
        {
            if (p.Length <= 7)
            {
                byte[] d = new byte[8]; d[0] = (byte)p.Length; Array.Copy(p, 0, d, 1, p.Length); o.Add(new CanFrame(RespId, d));
            }
            else
            {
                byte[] ff = new byte[8]; ff[0] = (byte)(0x10 | ((p.Length >> 8) & 0xF)); ff[1] = (byte)(p.Length & 0xFF);
                Array.Copy(p, 0, ff, 2, 6); o.Add(new CanFrame(RespId, ff));
                txBuf = p; txOff = 6; txSn = 1;
            }
        }
        void Neg(List<CanFrame> o, byte sid, byte nrc) { Respond(o, new byte[] { 0x7F, sid, nrc }); }

        void Handle(byte[] p, List<CanFrame> o)
        {
            byte sid = p[0]; Requests++;
            if (UnsafeSids.Contains(sid)) UnsafeRequestsSeen++;
            if (sid == 0x10 && p.Length > 1 && (p[1] & 0x7F) == 0x02) UnsafeRequestsSeen++; // programming session
            if (BusyEvery > 0 && Requests % BusyEvery == 0) { Neg(o, sid, 0x21); return; }
            if (PendingEvery > 0 && Requests % PendingEvery == 0) Respond(o, new byte[] { 0x7F, sid, 0x78 });

            switch (sid)
            {
                case 0x10:
                    if (p.Length != 2) { Neg(o, sid, 0x13); return; }
                    byte sub = (byte)(p[1] & 0x7F);
                    if (sub != 1 && sub != 2 && sub != 3) { Neg(o, sid, 0x12); return; }
                    session = sub; unlocked = false; currentSeed = null;
                    Respond(o, new byte[] { 0x50, sub, 0x00, 0x32, 0x01, 0xF4 }); return;
                case 0x3E:
                    Respond(o, new byte[] { 0x7E, 0x00 }); return;
                case 0x22:
                    if (p.Length != 3) { Neg(o, sid, 0x13); return; }
                    string v = null; int did = (p[1] << 8) | p[2];
                    if (did == 0xF190) v = "FREEOBDVIRT000001";
                    else if (did == 0xF187) v = "VIRT-PN-0001";
                    else if (did == 0xF189) v = "VIRT-CAL-1.0";
                    if (v == null) { Neg(o, sid, 0x31); return; }
                    byte[] r = new byte[3 + v.Length]; r[0] = 0x62; r[1] = p[1]; r[2] = p[2];
                    for (int i = 0; i < v.Length; i++) r[3 + i] = (byte)v[i];
                    Respond(o, r); return;
                case 0x27:
                    if (p.Length < 2) { Neg(o, sid, 0x13); return; }
                    if (session != 3) { Neg(o, sid, 0x7F); return; }
                    if (p[1] == 1)
                    {
                        if (lockedOut) { Neg(o, sid, 0x37); return; }
                        byte[] seed = new byte[4];
                        if (!unlocked) { rng.NextBytes(seed); currentSeed = seed; }
                        Respond(o, new byte[] { 0x67, 0x01, seed[0], seed[1], seed[2], seed[3] }); return;
                    }
                    if (p[1] == 2)
                    {
                        if (currentSeed == null || p.Length != 6) { Neg(o, sid, 0x24); return; }
                        byte[] want = DemoKey(currentSeed); currentSeed = null; bool ok = true;
                        for (int i = 0; i < 4; i++) if (p[2 + i] != want[i]) ok = false;
                        if (ok) { unlocked = true; badKeys = 0; Respond(o, new byte[] { 0x67, 0x02 }); return; }
                        badKeys++;
                        if (badKeys >= 3) { lockedOut = true; Neg(o, sid, 0x36); } else Neg(o, sid, 0x35);
                        return;
                    }
                    Neg(o, sid, 0x12); return;
                case 0x23:
                    if (p.Length < 2) { Neg(o, sid, 0x13); return; }
                    if (session != 3) { Neg(o, sid, 0x7F); return; }
                    if (!unlocked) { Neg(o, sid, 0x33); return; }
                    int alen = p[1] & 0xF, slen = p[1] >> 4;
                    if (alen < 1 || slen < 1 || p.Length != 2 + alen + slen) { Neg(o, sid, 0x13); return; }
                    long addr = 0, size = 0;
                    for (int i = 0; i < alen; i++) addr = (addr << 8) | p[2 + i];
                    for (int i = 0; i < slen; i++) size = (size << 8) | p[2 + alen + i];
                    if (size < 1 || size > 0xFFF || addr < BaseAddress || addr + size > BaseAddress + Memory.Length) { Neg(o, sid, 0x31); return; }
                    byte[] resp = new byte[1 + size]; resp[0] = 0x63;
                    Array.Copy(Memory, (int)(addr - BaseAddress), resp, 1, (int)size);
                    Respond(o, resp); return;
                default:
                    Neg(o, sid, 0x11); return;
            }
        }
    }
}
