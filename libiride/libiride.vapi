[CCode (cheader_filename = "libiride.h")]
namespace Iride {
	[CCode (cname = "iride_check")]
	public int check ([CCode (array_length_type = "size_t")] uint8[] data);

	[CCode (cname = "iride_pick")]
	public int pick ([CCode (array_length_type = "size_t")] uint8[] data, uint32 pixels,
		[CCode (array_length_type = "size_t")] out unowned uint8[] png, out uint32 size);

	[CCode (cname = "iride_motion")]
	public int motion ([CCode (array_length_type = "size_t")] uint8[] data, uint32 pixels,
		out uint32 duration, out uint32 size, out size_t work_len);

	[CCode (cname = "iride_prepare")]
	public int prepare ([CCode (array_length_type = "size_t")] uint8[] data, uint32 pixels,
		[CCode (array_length_type = "size_t")] uint8[] work);

	[CCode (cname = "iride_frame")]
	public int frame ([CCode (array_length_type = "size_t")] uint8[] data, uint32 pixels, double msec,
		[CCode (array_length_type = "size_t")] uint8[] work,
		[CCode (array_length_type = "size_t")] uint8[] pixels_out);

	[CCode (cname = "uint32_t", cprefix = "IRIDE_", has_type_id = false)]
	public enum Scheme {
		LIGHT,
		DARK
	}

	[CCode (cname = "uint32_t", cprefix = "IRIDE_ACCENT_", has_type_id = false)]
	public enum Accent {
		NONE,
		BLACK,
		WHITE
	}

	[CCode (cname = "iride_variant")]
	public int variant ([CCode (array_length_type = "size_t")] uint8[] data, Scheme scheme, Accent accent,
		[CCode (array_length_type = "size_t")] out unowned uint8[] found);

	[CCode (cname = "IRIDE_NO_ACCENT")]
	public const uint32 NO_ACCENT;

	[CCode (cname = "iride_look")]
	public int look ([CCode (array_length_type = "size_t")] uint8[] data, Scheme scheme, bool accented,
		[CCode (array_length_type = "size_t")] out unowned uint8[] black,
		[CCode (array_length_type = "size_t")] out unowned uint8[]? white);

	[CCode (cname = "iride_still")]
	public int still ([CCode (array_length_type = "size_t")] uint8[] data, uint32 pixels, Scheme scheme, uint32 accent,
		[CCode (array_length_type = "size_t")] uint8[] pixels_out, out uint32 size);

	[CCode (cname = "iride_tint")]
	public int tint ([CCode (array_length = false)] uint8[] black,
		[CCode (array_length_type = "size_t")] uint8[] white, uint32 rgb,
		[CCode (array_length_type = "size_t")] uint8[] pixels_out);
}
