#include <linux/module.h>
#include <linux/export-internal.h>
#include <linux/compiler.h>

MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};



static const struct modversion_info ____versions[]
__used __section("__versions") = {
	{ 0x47a82b63, "kobject_create_and_add" },
	{ 0xc0dc64e6, "sysfs_create_group" },
	{ 0x9acc1e61, "kobject_put" },
	{ 0x99f2d00a, "sysfs_emit_at" },
	{ 0xbb10e61d, "unregister_kprobe" },
	{ 0x5b5bbd31, "sysfs_remove_group" },
	{ 0xbdfb6dbb, "__fentry__" },
	{ 0x5b8239ca, "__x86_return_thunk" },
	{ 0x3f66a26e, "register_kprobe" },
	{ 0x92997ed8, "_printk" },
	{ 0x5abebffa, "kernel_kobj" },
	{ 0x2f9b2b9a, "module_layout" },
};

MODULE_INFO(depends, "");


MODULE_INFO(srcversion, "DE9B7B92BB7F62AC152764E");
