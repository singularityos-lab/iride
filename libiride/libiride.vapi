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
}
