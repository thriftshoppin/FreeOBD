using System;
using System.Collections.Generic;
using System.IO;

namespace FreeObd
{
    public struct CanFrame
    {
        public uint Id;
        public byte[] Data; // always 8 bytes
        public CanFrame(uint id, byte[] data) { Id = id; Data = data; }
    }

    /// <summary>Raw CAN transport. Real adapters (J2534, ELM327) and the virtual bus implement this.</summary>
    public interface ICanBus
    {
        void Send(CanFrame f);
        bool TryReceive(out CanFrame f); // false = timeout / nothing received
        void Flush();                    // discard anything pending
    }

    /// <summary>ISO 15765-2 (ISO-TP) segmentation, tester side.</summary>
    public class IsoTp
    {
        readonly ICanBus bus; readonly uint txId, rxId;
        public IsoTp(ICanBus bus, uint txId, uint rxId) { this.bus = bus; this.txId = txId; this.rxId = rxId; }

        static byte[] Pad() { return new byte[] { 0, 0, 0, 0, 0, 0, 0, 0 }; }

        public void Send(byte[] p)
        {
            bus.Flush();
            if (p.Length > 4095) throw new ArgumentException("payload too large");
            if (p.Length <= 7)
            {
                byte[] d = Pad(); d[0] = (byte)p.Length; Array.Copy(p, 0, d, 1, p.Length);
                bus.Send(new CanFrame(txId, d));
                return;
            }
            byte[] ff = Pad();
            ff[0] = (byte)(0x10 | ((p.Length >> 8) & 0xF)); ff[1] = (byte)(p.Length & 0xFF);
            Array.Copy(p, 0, ff, 2, 6);
            bus.Send(new CanFrame(txId, ff));
            CanFrame fc;
            if (!bus.TryReceive(out fc) || fc.Id != rxId || (fc.Data[0] >> 4) != 3) throw new TimeoutException("no flow control");
            if ((fc.Data[0] & 0xF) != 0) throw new IOException("flow control status " + (fc.Data[0] & 0xF));
            int off = 6; byte sn = 1;
            while (off < p.Length)
            {
                int n = Math.Min(7, p.Length - off);
                byte[] cf = Pad(); cf[0] = (byte)(0x20 | sn); Array.Copy(p, off, cf, 1, n);
                bus.Send(new CanFrame(txId, cf));
                off += n; sn = (byte)((sn + 1) & 0xF);
            }
        }

        public byte[] Receive()
        {
            CanFrame f;
            do { if (!bus.TryReceive(out f)) throw new TimeoutException("no response"); } while (f.Id != rxId);
            int type = f.Data[0] >> 4;
            if (type == 0)
            {
                int n = f.Data[0] & 0xF;
                if (n < 1 || n > 7) throw new IOException("bad single frame length");
                byte[] r = new byte[n]; Array.Copy(f.Data, 1, r, 0, n); return r;
            }
            if (type != 1) throw new IOException("unexpected frame type " + type);
            int len = ((f.Data[0] & 0xF) << 8) | f.Data[1];
            if (len < 8) throw new IOException("bad first frame length");
            byte[] buf = new byte[len]; Array.Copy(f.Data, 2, buf, 0, 6);
            byte[] fcf = Pad(); fcf[0] = 0x30;
            bus.Send(new CanFrame(txId, fcf));
            int pos = 6; byte sn = 1;
            while (pos < len)
            {
                if (!bus.TryReceive(out f)) throw new TimeoutException("multi-frame response truncated");
                if (f.Id != rxId) continue;
                if ((f.Data[0] >> 4) != 2 || (f.Data[0] & 0xF) != sn) throw new IOException("consecutive frame sequence error");
                int n = Math.Min(7, len - pos);
                Array.Copy(f.Data, 1, buf, pos, n);
                pos += n; sn = (byte)((sn + 1) & 0xF);
            }
            return buf;
        }
    }

    /// <summary>In-process CAN bus wired to a VirtualEcu. RxHook lets tests drop or corrupt frames.</summary>
    public class VirtualBus : ICanBus
    {
        readonly VirtualEcu ecu; readonly Queue<CanFrame> rx = new Queue<CanFrame>();
        int rxCount;
        public Func<int, CanFrame, CanFrame?> RxHook;
        public int TxFrames;
        public VirtualBus(VirtualEcu ecu) { this.ecu = ecu; }
        public void Send(CanFrame f)
        {
            TxFrames++;
            foreach (CanFrame r in ecu.OnFrame(f))
            {
                rxCount++;
                CanFrame? x = r;
                if (RxHook != null) x = RxHook(rxCount, r);
                if (x.HasValue) rx.Enqueue(x.Value);
            }
        }
        public bool TryReceive(out CanFrame f)
        {
            if (rx.Count > 0) { f = rx.Dequeue(); return true; }
            f = default(CanFrame); return false;
        }
        public void Flush() { rx.Clear(); }
    }
}
