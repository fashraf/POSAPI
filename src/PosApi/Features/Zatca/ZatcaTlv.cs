using System.Text;

namespace PosApi.Features.Zatca;

/// <summary>
/// The QR payload: tag, length, value, then base64.
///
/// The length takes BER's long form from 128 bytes (one byte up to 127, then
/// 0x81 n, then 0x82 hi lo), as ZATCA's SDK writes it. The guideline's text
/// says "one byte", the SDK disagrees above 127, and no sample settles it, so
/// the seller name is capped at 127 bytes upstream and no shipped value
/// depends on the long form. Mirrors sales.fn_ZatcaTlv (migration 022).
/// </summary>
public static class ZatcaTlv
{
    /// <summary>The guideline's ceiling for the base64 payload.</summary>
    public const int MaxBase64Length = 700;

    public static byte[] Field(int tag, byte[] value)
    {
        if (tag is < 1 or > 255) throw new ArgumentOutOfRangeException(nameof(tag));
        if (value.Length > 65535) throw new ArgumentException("TLV value too long.", nameof(value));

        var output = new List<byte>(value.Length + 4) { (byte)tag };
        if (value.Length < 128)
        {
            output.Add((byte)value.Length);
        }
        else if (value.Length < 256)
        {
            output.Add(0x81);
            output.Add((byte)value.Length);
        }
        else
        {
            output.Add(0x82);
            output.Add((byte)(value.Length >> 8));
            output.Add((byte)(value.Length & 0xFF));
        }
        output.AddRange(value);
        return [.. output];
    }

    public static byte[] Field(int tag, string value) => Field(tag, Encoding.UTF8.GetBytes(value));

    /// <summary>Fields in order, as one base64 string.</summary>
    public static string Encode(params byte[][] fields) => Convert.ToBase64String(fields.SelectMany(f => f).ToArray());

    /// <summary>The fields of a payload, by tag (for tests and checks).</summary>
    public static IReadOnlyList<(int Tag, byte[] Value)> Decode(string base64)
    {
        var bytes = Convert.FromBase64String(base64);
        var fields = new List<(int, byte[])>();
        var i = 0;
        while (i < bytes.Length)
        {
            int tag = bytes[i++];
            int length = bytes[i++];
            if (length == 0x81) length = bytes[i++];
            else if (length == 0x82) { length = (bytes[i] << 8) | bytes[i + 1]; i += 2; }
            fields.Add((tag, bytes[i..(i + length)]));
            i += length;
        }
        return fields;
    }
}
