[CCode (cheader_filename = "libiride.h")]
namespace Iride {
	[CCode (cname = "iride_check")]
	public int check ([CCode (array_length_type = "size_t")] uint8[] data);

	[CCode (cname = "iride_pick")]
	public int pick ([CCode (array_length_type = "size_t")] uint8[] data, uint32 pixels,
		[CCode (array_length_type = "size_t")] out unowned uint8[] png, out uint32 size);
}
