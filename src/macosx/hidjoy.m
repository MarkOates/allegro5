/*         ______   ___    ___
 *        /\  _  \ /\_ \  /\_ \
 *        \ \ \L\ \\//\ \ \//\ \      __     __   _ __   ___
 *         \ \  __ \ \ \ \  \ \ \   /'__`\ /'_ `\/\`'__\/ __`\
 *          \ \ \/\ \ \_\ \_ \_\ \_/\  __//\ \L\ \ \ \//\ \L\ \
 *           \ \_\ \_\/\____\/\____\ \____\ \____ \ \_\\ \____/
 *            \/_/\/_/\/____/\/____/\/____/\/___L\ \/_/ \/___/
 *                                           /\____/
 *                                           \_/__/
 *
 *      HID Joystick driver routines for MacOS X.
 *
 *      By Angelo Mottola.
 *      New API (Leopard) support and hotplugging by Trent Gamblin.
 *
 *      See readme.txt for copyright information.
 */

#include "allegro5/allegro.h"
#include "allegro5/platform/aintosx.h"

#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/hid/IOHIDKeys.h>

#ifndef ALLEGRO_MACOSX
#error something is wrong with the makefile
#endif

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1050

#import <IOKit/hid/IOHIDBase.h>

/* State transitions:
 *    unused -> born
 *    born -> alive
 *    born -> dying
 *    active -> dying
 *    dying -> unused
 */
typedef enum {
   JOY_STATE_UNUSED,
   JOY_STATE_BORN,
   JOY_STATE_ALIVE,
   JOY_STATE_DYING
} CONFIG_STATE;

// These values can be found in the USB HID Usage Tables:
// http://www.usb.org/developers/hidpage
#define GENERIC_DESKTOP_USAGE_PAGE 0x01
#define JOYSTICK_USAGE_NUMBER      0x04
#define GAMEPAD_USAGE_NUMBER       0x05

typedef struct {
   ALLEGRO_JOYSTICK parent;
   IOHIDElementRef buttons[_AL_MAX_JOYSTICK_BUTTONS];
   IOHIDElementRef axes[_AL_MAX_JOYSTICK_STICKS][_AL_MAX_JOYSTICK_AXES];
   IOHIDElementRef dpad;
   int dpad_stick;
   int dpad_axis_vert;
   int dpad_axis_horiz;
   long min[_AL_MAX_JOYSTICK_STICKS][_AL_MAX_JOYSTICK_AXES];
   long max[_AL_MAX_JOYSTICK_STICKS][_AL_MAX_JOYSTICK_AXES];
   CONFIG_STATE cfg_state;
   ALLEGRO_JOYSTICK_STATE state;
   IOHIDDeviceRef ident;
} ALLEGRO_JOYSTICK_OSX;

static IOHIDManagerRef hidManagerRef;
static _AL_VECTOR joysticks;
static CONFIG_STATE new_joystick_state = JOY_STATE_ALIVE;
static bool initialized = false;
static ALLEGRO_MUTEX *add_mutex;
static CFRunLoopRef run_loop_ref;

ALLEGRO_DEBUG_CHANNEL("MacOSX")

// function to create matching dictionary (for devices)
static CFMutableDictionaryRef CreateDeviceMatchingDictionary(
   UInt32 inUsagePage,
   UInt32 inUsage
) {
   // create a dictionary to add usage page/usages to
   CFMutableDictionaryRef result = CFDictionaryCreateMutable(
      kCFAllocatorDefault,
      0,
      &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks
   );

   if (result) {
      // Add key for device type to refine the matching dictionary.
      CFNumberRef pageCFNumberRef = CFNumberCreate(
         kCFAllocatorDefault,
         kCFNumberIntType,
         &inUsagePage
      );

      if (pageCFNumberRef) {
         CFStringRef usage_page = CFSTR(kIOHIDDeviceUsagePageKey);

         CFDictionarySetValue(
            result,
            usage_page,
            pageCFNumberRef
         );

         CFRelease(pageCFNumberRef);

         // note: the usage is only valid if the usage page is also defined

         CFNumberRef usageCFNumberRef = CFNumberCreate(
            kCFAllocatorDefault,
            kCFNumberIntType,
            &inUsage
         );

         if (usageCFNumberRef) {
            CFStringRef usage_key = CFSTR(kIOHIDDeviceUsageKey);

            CFDictionarySetValue(
               result,
               usage_key,
               usageCFNumberRef
            );

            CFRelease(usageCFNumberRef);
         }
      }
   }

   return result;
}

static ALLEGRO_JOYSTICK_OSX *find_joystick(IOHIDDeviceRef ident)
{
   int i;
   for (i = 0; i < (int)_al_vector_size(&joysticks); i++) {
      ALLEGRO_JOYSTICK_OSX *joy = *(ALLEGRO_JOYSTICK_OSX **)_al_vector_ref(&joysticks, i);
      if (ident == joy->ident) {
         return joy;
      }
   }

   return NULL;
}

static const char *get_element_name(IOHIDElementRef elem, const char *default_name)
{
   CFStringRef name = IOHIDElementGetName(elem);
   if (name) {
      return CFStringGetCStringPtr(name, kCFStringEncodingUTF8);
   }
   else
      return default_name;
}



static void add_axis(ALLEGRO_JOYSTICK_OSX *joy, int stick_index, int axis_index, int min, int max, char *name, IOHIDElementRef elem)
{
   if (axis_index >= _AL_MAX_JOYSTICK_AXES)
      return;

   joy->min[stick_index][axis_index] = min;
   joy->max[stick_index][axis_index] = max;

   joy->parent.info.stick[stick_index].axis[axis_index].name = name;
   joy->parent.info.stick[stick_index].num_axes++;
   joy->axes[stick_index][axis_index] = elem;
}


static void populate_elements(ALLEGRO_JOYSTICK_OSX *joy)
{
   int i, j;
   char default_name[100];
   int stick_class = -1;
   int axis_index = 0;

   CFArrayRef elements = IOHIDDeviceCopyMatchingElements(
      joy->ident,
      NULL,
      kIOHIDOptionsTypeNone
   );

   // NULL the parent
   for (i = 0; i < _AL_MAX_JOYSTICK_BUTTONS; i++)
   {
      joy->parent.info.button[i].name = NULL;
   }
   for (i = 0; i < _AL_MAX_JOYSTICK_STICKS; i++)
   {
      joy->parent.info.stick[i].name = NULL;

      for (j = 0; j < _AL_MAX_JOYSTICK_AXES; j++) {
         joy->parent.info.stick[i].axis[j].name = NULL;
      }
   }

   for (i = 0; i < CFArrayGetCount(elements); i++) {
      IOHIDElementRef elem = (IOHIDElementRef)CFArrayGetValueAtIndex(
         elements,
         i
      );

      int usage = IOHIDElementGetUsage(elem);
      if (IOHIDElementGetType(elem) == kIOHIDElementTypeInput_Button) {
         if (usage >= 0 && usage < _AL_MAX_JOYSTICK_BUTTONS &&
            !joy->buttons[usage-1]) {
            joy->buttons[usage-1] = elem;
            sprintf(default_name, "Button %d", usage-1);
            const char *name = get_element_name(elem, default_name);
            char *str = al_malloc(strlen(name)+1);
            strcpy(str, name);
            joy->parent.info.button[usage-1].name = str;
            joy->parent.info.num_buttons++;
         }
      }
      else if (
         IOHIDElementGetType(elem) == kIOHIDElementTypeInput_Misc) {
         long min = IOHIDElementGetLogicalMin(elem);
         long max = IOHIDElementGetLogicalMax(elem);
         int new_stick_class = -1;
         int stick_index = joy->parent.info.num_sticks - 1;

         switch (usage) {
            case kHIDUsage_GD_X:
            case kHIDUsage_GD_Y:
            case kHIDUsage_GD_Z:
               new_stick_class = 1;
               break;

            case kHIDUsage_GD_Rx:
            case kHIDUsage_GD_Ry:
            case kHIDUsage_GD_Rz:
               new_stick_class = 2;
               break;

            case kHIDUsage_GD_Hatswitch:
               new_stick_class = 3;
               break;
         }

         if (new_stick_class < 0)
            continue;

         if (stick_class != new_stick_class) {
            if (joy->parent.info.num_sticks >= _AL_MAX_JOYSTICK_STICKS-1)
               break;

            joy->parent.info.num_sticks++;

            stick_index++;
            axis_index = 0;

            stick_class = new_stick_class;

            char *buf = al_malloc(20);
            sprintf(buf, "Stick %d", stick_index);
            joy->parent.info.stick[stick_index].name = buf;
         }
         else
            axis_index++;

         if (stick_class == 3) {
            joy->dpad_stick = stick_index;
            joy->dpad = elem;

            joy->dpad_axis_horiz = axis_index;
            sprintf(default_name, "Axis %i", axis_index);
            char *str = al_malloc(strlen(default_name)+1);
            strcpy(str, default_name);
            joy->parent.info.stick[stick_index].axis[axis_index].name = str;

            ++axis_index;
            joy->dpad_axis_vert = axis_index;
            sprintf(default_name, "Axis %i", axis_index);
            str = al_malloc(strlen(default_name)+1);
            strcpy(str, default_name);
            add_axis(joy, stick_index, axis_index, min, max, str, elem);
            joy->parent.info.stick[stick_index].axis[axis_index].name = str;

            joy->parent.info.stick[stick_index].num_axes = 2;
         }
         else {
            sprintf(default_name, "Axis %i", axis_index);
            const char *name = get_element_name(elem, default_name);
            char *str = al_malloc(strlen(name)+1);
            strcpy(str, name);
            add_axis(joy, stick_index, axis_index, min, max, str, elem);
         }
      }
   }

   CFRelease(elements);
}

static void osx_joy_generate_configure_event(void)
{
   if (!initialized) return;

   ALLEGRO_EVENT event;
   event.joystick.type = ALLEGRO_EVENT_JOYSTICK_CONFIGURATION;
   event.joystick.timestamp = al_current_time();

   _al_generate_joystick_event(&event);
}

static void add_joystick_device(IOHIDDeviceRef ref, bool emit_reconfigure_event)
{
   al_lock_mutex(add_mutex);

   ALLEGRO_JOYSTICK_OSX *joy = find_joystick(ref);

   if (joy)
   {
      // Prevent multiple re-creations of a joystick if it alredy exists.
      al_unlock_mutex(add_mutex);
      return;
   }

   if (joy == NULL) {
      joy = al_calloc(1, sizeof(ALLEGRO_JOYSTICK_OSX));
      joy->ident = ref;
      ALLEGRO_JOYSTICK_OSX **back = _al_vector_alloc_back(&joysticks);
      *back = joy;
   }
   joy->cfg_state = new_joystick_state;

   populate_elements(joy);

   al_unlock_mutex(add_mutex);

   if (emit_reconfigure_event) osx_joy_generate_configure_event();

   ALLEGRO_INFO("Found joystick (%d buttons, %d sticks)\n",
      joy->parent.info.num_buttons, joy->parent.info.num_sticks);
}

static void device_add_callback(
   void *context,
   IOReturn result,
   void *sender,
   IOHIDDeviceRef ref
) {
   (void)context;
   (void)result;
   (void)sender;

   add_joystick_device(ref, true);
}

static void device_remove_callback(
   void *context,
   IOReturn result,
   void *sender,
   IOHIDDeviceRef ref
) {
   (void)context;
   (void)result;
   (void)sender;

   int i;
   for (i = 0; i < (int)_al_vector_size(&joysticks); i++) {
      ALLEGRO_JOYSTICK_OSX *joy = *(ALLEGRO_JOYSTICK_OSX **)_al_vector_ref(&joysticks, i);
      if (joy->ident == ref) {
         joy->cfg_state = JOY_STATE_DYING;
         osx_joy_generate_configure_event();
         return;
      }
   }
}

static void osx_joy_generate_axis_event(ALLEGRO_JOYSTICK_OSX *joy, int stick, int axis, float pos)
{
   joy->state.stick[stick].axis[axis] = pos;

   ALLEGRO_EVENT event;
   ALLEGRO_EVENT_SOURCE *es = al_get_joystick_event_source();

   if (!_al_event_source_needs_to_generate_event(es))
      return;

   event.joystick.type = ALLEGRO_EVENT_JOYSTICK_AXIS;
   event.joystick.timestamp = al_current_time();
   event.joystick.id = (ALLEGRO_JOYSTICK *)joy;
   event.joystick.stick = stick;
   event.joystick.axis = axis;
   event.joystick.pos = pos;
   event.joystick.button = 0;

   _al_event_source_emit_event(es, &event);
}

static void osx_joy_generate_button_event(ALLEGRO_JOYSTICK_OSX *joy, int button, ALLEGRO_EVENT_TYPE event_type)
{
   joy->state.button[button] = event_type == ALLEGRO_EVENT_JOYSTICK_BUTTON_UP ?
      0 : 1;;

   ALLEGRO_EVENT event;
   ALLEGRO_EVENT_SOURCE *es = al_get_joystick_event_source();

   if (!_al_event_source_needs_to_generate_event(es))
      return;

   event.joystick.type = event_type;
   event.joystick.timestamp = al_current_time();
   event.joystick.id = (ALLEGRO_JOYSTICK *)joy;
   event.joystick.stick = 0;
   event.joystick.axis = 0;
   event.joystick.pos = 0.0;
   event.joystick.button = button;

   _al_event_source_emit_event(es, &event);
}

#define MAX_HAT_DIRECTIONS 9
struct HAT_MAPPING {
   int axisV;
   int axisH;
} hat_mapping[MAX_HAT_DIRECTIONS] = {
   { -1,  0 }, // 0
   { -1,  1 }, // 1
   {  0,  1 }, // 2
   {  1,  1 }, // 3
   {  1,  0 }, // 4
   {  1, -1 }, // 5
   {  0, -1 }, // 6
   { -1, -1 }, // 7
   {  0,  0 }, // 8
};

static void value_callback(
   void *context,
   IOReturn result,
   void *sender,
   IOHIDValueRef value
) {
   if (!initialized) return;

   (void)context;
   (void)result;
   (void)sender;

   IOHIDElementRef elem = IOHIDValueGetElement(value);
   IOHIDDeviceRef ref = IOHIDElementGetDevice(elem);
   ALLEGRO_JOYSTICK_OSX *joy = find_joystick(ref);

   if (!joy) return;

   ALLEGRO_EVENT_SOURCE *es = al_get_joystick_event_source();
   _al_event_source_lock(es);

   int i;
   for (i = 0; i < joy->parent.info.num_buttons; i++) {
      if (joy->buttons[i] == elem) {
         ALLEGRO_EVENT_TYPE type;
         if (IOHIDValueGetIntegerValue(value) == 0)
            type = ALLEGRO_EVENT_JOYSTICK_BUTTON_UP;
         else
            type = ALLEGRO_EVENT_JOYSTICK_BUTTON_DOWN;
         osx_joy_generate_button_event(joy, i, type);
         goto done;
      }
   }

   int int_value = IOHIDValueGetIntegerValue(value);

   if (joy->dpad == elem){
      if (int_value >= 0 && int_value < MAX_HAT_DIRECTIONS) {
         osx_joy_generate_axis_event(joy, joy->dpad_stick, joy->dpad_axis_vert,  (float)hat_mapping[int_value].axisV);
         osx_joy_generate_axis_event(joy, joy->dpad_stick, joy->dpad_axis_horiz, (float)hat_mapping[int_value].axisH);
      }
      goto done;
   }

   int stick = -1;
   int axis = -1;
   for (stick = 0; stick < joy->parent.info.num_sticks; stick++) {
      for(axis = 0; axis < joy->parent.info.stick[stick].num_axes; ++axis) {
         if (joy->axes[stick][axis] == elem) {
            goto gen_axis_event;
         }
      }
   }

   // Unknown event
   goto done;

gen_axis_event:
   {
      float pos;
      long min = joy->min[stick][axis];
      long max = joy->max[stick][axis];
      if (min < 0) {
         if (int_value < 0)
            pos = -(float)int_value/min;
         else
            pos = (float)int_value/max;
      }
      else {
         pos = ((float)int_value/max*2) - 1;
      }

      osx_joy_generate_axis_event(joy, stick, axis, pos);
   }

done:
   _al_event_source_unlock(es);
}

static IOHIDManagerRef create_hid_manager_for_joysticks()
{
   IOHIDManagerRef result = IOHIDManagerCreate(
      kCFAllocatorDefault,
      kIOHIDOptionsTypeNone
   );

   if (CFGetTypeID(result) != IOHIDManagerGetTypeID()) {
      ALLEGRO_ERROR("Unable to create HID Manager\n");
      return false;
   }

   // Set which devices we want to match
   CFMutableDictionaryRef criteria0 = CreateDeviceMatchingDictionary(
      GENERIC_DESKTOP_USAGE_PAGE,
      JOYSTICK_USAGE_NUMBER
   );
   CFMutableDictionaryRef criteria1 = CreateDeviceMatchingDictionary(
      GENERIC_DESKTOP_USAGE_PAGE,
      GAMEPAD_USAGE_NUMBER
   );
   CFMutableDictionaryRef criteria_list[] = {
      criteria0,
      criteria1
   };
   CFArrayRef criteria = CFArrayCreate(
      kCFAllocatorDefault,
      (const void **)criteria_list,
      2, NULL
   );

   IOHIDManagerSetDeviceMatchingMultiple(
      result,
      criteria
   );

   CFRelease(criteria0);
   CFRelease(criteria1);
   CFRelease(criteria);

   return result;
}


static destroy_hid_manager_for_joysticks(IOHIDManagerRef manager)
{
   // Close our manager
   IOHIDManagerClose(
      manager,
      kIOHIDOptionsTypeNone
   );
   CFRelease(manager);
}


static register_hid_manager_for_hotplugging_callbacks(IOHIDManagerRef manager)
{
   /* Register for plug/unplug notifications */
   IOHIDManagerRegisterDeviceMatchingCallback(
      hidManagerRef,
      device_add_callback,
      NULL
   );
   IOHIDManagerRegisterDeviceRemovalCallback(
      hidManagerRef,
      device_remove_callback,
      NULL
   );
}


static unregister_hid_manager_for_hotplugging_callbacks(IOHIDManagerRef manager)
{
   // Unregister from hotplugging changes
   IOHIDManagerRegisterDeviceMatchingCallback(
      hidManagerRef,
      NULL,
      NULL
   );
   IOHIDManagerRegisterDeviceRemovalCallback(
      hidManagerRef,
      NULL,
      NULL
   );
}


static register_hid_manager_for_value_change_callbacks(IOHIDManagerRef manager)
{
   // Register for value changes
   IOHIDManagerRegisterInputValueCallback(
      hidManagerRef,
      value_callback,
      NULL
   );
}


static unregister_hid_manager_for_value_change_callbacks(IOHIDManagerRef manager)
{
   // Unregister from value changes
   IOHIDManagerRegisterInputValueCallback(
      hidManagerRef,
      NULL,
      NULL
   );
}


static schedule_hid_manager_with_run_loop(IOHIDManagerRef manager)
{
   run_loop_ref = CFRunLoopGetMain();

   IOHIDManagerScheduleWithRunLoop(
      hidManagerRef,
      run_loop_ref,
      kCFRunLoopDefaultMode
   );
}


static unschedule_hid_manager_with_run_loop(IOHIDManagerRef manager)
{
   IOHIDManagerUnscheduleFromRunLoop(
      hidManagerRef,
      run_loop_ref,
      kCFRunLoopDefaultMode
   );

}


static enumerate_and_create_initial_joystick_devices(IOHIDManagerRef manager)
{
   int i;

   CFSetRef devices = IOHIDManagerCopyDevices(manager);
   if (devices == NULL)
   {
      // There are no devices to enumerate
      printf("There are no devices to enumerate.\n");
   }
   else
   {
      CFIndex num_devices = CFSetGetCount(devices);
      IOHIDDeviceRef *device_arr = calloc(num_devices, sizeof(IOHIDDeviceRef));
      CFSetGetValues(devices, (const void **) device_arr);

      printf("Num devices: %d\n", num_devices);

      for (i = 0; i < num_devices; i++) {
         IOHIDDeviceRef dev = device_arr[i];
         printf("Device: %p\n", dev);
         add_joystick_device(dev, false);
      }
   }
}


/* init_joystick:
 *  Initializes the HID joystick driver.
 */
static bool init_joystick(void)
{
   add_mutex = al_create_mutex();

   hidManagerRef = create_hid_manager_for_joysticks();

   register_hid_manager_for_hotplugging_callbacks(hidManagerRef);
   register_hid_manager_for_value_change_callbacks(hidManagerRef);
   schedule_hid_manager_with_run_loop(hidManagerRef);

   _al_vector_init(&joysticks, sizeof(ALLEGRO_JOYSTICK_OSX *));

   al_lock_mutex(add_mutex);

   IOReturn ret = IOHIDManagerOpen(
      hidManagerRef,
      kIOHIDOptionsTypeSeizeDevice
   );

   al_unlock_mutex(add_mutex);

   if (ret != kIOReturnSuccess) {
      return false;
   }

   enumerate_and_create_initial_joystick_devices(hidManagerRef);

   new_joystick_state = JOY_STATE_BORN;

   initialized = true;

   return true;
}

/* exit_joystick:
 *  Shuts down the HID joystick driver.
 */
static void exit_joystick(void)
{
   al_destroy_mutex(add_mutex);

   unschedule_hid_manager_with_run_loop(hidManagerRef);
   unregister_hid_manager_for_value_change_callbacks(hidManagerRef);
   unregister_hid_manager_for_hotplugging_callbacks(hidManagerRef);

   destroy_hid_manager_for_joysticks(hidManagerRef);

   _al_vector_free(&joysticks);

   initialized = false;
}

/* num_joysticks:
 *  Return number of active joysticks
 */
static int num_active_joysticks(void)
{
   int i;
   int count = 0;
   for (i = 0; i < (int)_al_vector_size(&joysticks); i++) {
      ALLEGRO_JOYSTICK_OSX *joy = *(ALLEGRO_JOYSTICK_OSX **)_al_vector_ref(&joysticks, i);
      if (joy->cfg_state == JOY_STATE_ALIVE) {
         count++;
      }
   }

   return count;
}

/* get_joystick:
 * Get a pointer to a joystick structure
 */
static ALLEGRO_JOYSTICK* get_joystick(int index)
{
   ASSERT(index >= 0 && index < (int)_al_vector_size(&joysticks));

   int i;
   int count = 0;
   for (i = 0; i < (int)_al_vector_size(&joysticks); i++) {
      ALLEGRO_JOYSTICK_OSX *joy = *(ALLEGRO_JOYSTICK_OSX **)_al_vector_ref(&joysticks, i);
      if (joy->cfg_state == JOY_STATE_ALIVE ||
         joy->cfg_state == JOY_STATE_DYING) {
            if (count == index) {
               return (ALLEGRO_JOYSTICK *)joy;
            }
            count++;
      }
   }

   return NULL;
}

/* release_joystick:
 * Release a pointer that has been obtained
 */
static void release_joystick(ALLEGRO_JOYSTICK* joy __attribute__((unused)) )
{
   // No-op
}

/* get_joystick_state:
 * Get the current status of a joystick
 */
static void get_joystick_state(ALLEGRO_JOYSTICK *joy_, ALLEGRO_JOYSTICK_STATE *ret_state)
{
   ALLEGRO_JOYSTICK_OSX *joy = (ALLEGRO_JOYSTICK_OSX *) joy_;
   ALLEGRO_EVENT_SOURCE *es = al_get_joystick_event_source();

   _al_event_source_lock(es);
   {
      *ret_state = joy->state;
   }
   _al_event_source_unlock(es);
}


static int num_joysticks()
{
   return (int)_al_vector_size(&joysticks);
}


static ALLEGRO_JOYSTICK_OSX *joystick_at(int i)
{
   return *(ALLEGRO_JOYSTICK_OSX **)_al_vector_ref(&joysticks, i);
}


static bool reconfigure_joysticks(void)
{
   int i;

   for (i=0; i<num_joysticks(); i++)
   {
      ALLEGRO_JOYSTICK_OSX *joystick = joystick_at(i);

      switch(joystick->cfg_state)
      {
         case JOY_STATE_DYING:
           // The joystick has been disconnected by the OS, but the disconnection is not yet processed by Allegro

           // Clear out the button names on the ALLEGRO_JOYSTICK* parent
           for (i = 0; i < _AL_MAX_JOYSTICK_BUTTONS; i++)
           {
              al_free((char *)joystick->parent.info.button[i].name);
              joystick->parent.info.button[i].name = NULL;
           }

           // Clear out the stick names on the ALLEGRO_JOYSTICK* parent
           for (i = 0; i < _AL_MAX_JOYSTICK_STICKS; i++)
           {
              int j;
              al_free(joystick->parent.info.stick[i].name);

              for (j = 0; j < _AL_MAX_JOYSTICK_AXES; j++)
              {
                 al_free(joystick->parent.info.stick[i].axis[j].name);
                 joystick->parent.info.stick[i].axis[j].name = NULL;
              }
           }

           // Clear out the values on the ALLEGRO_JOYSTICK* parent
           memset(joystick->buttons, 0, _AL_MAX_JOYSTICK_BUTTONS*sizeof(IOHIDElementRef));
           memset(&joystick->state, 0, sizeof(ALLEGRO_JOYSTICK_STATE));
           joystick->dpad=0;

           // Set the state to "UNUSED", indicating that Allegro acknowledges and has processed its disconnection
           joystick->cfg_state = JOY_STATE_UNUSED;
         break;

         case JOY_STATE_BORN:
            // The joystick has been newly connected by the OS, but not yet acknowledged by Allegro

            // Set the state to "ALIVE", indicating that Allegro acknowledges its disconnection
            joystick->cfg_state = JOY_STATE_ALIVE;
         break;

         default:
            // There are no other states that require processing during reconfiguration
         break;
      }
   }

   return true;
}

// FIXME!
static const char *get_joystick_name(ALLEGRO_JOYSTICK *joy_)
{
   (void)joy_;
   return "Joystick";
}

static bool get_joystick_active(ALLEGRO_JOYSTICK *joy_)
{
   ALLEGRO_JOYSTICK_OSX *joy = (ALLEGRO_JOYSTICK_OSX *)joy_;
   return joy->cfg_state == JOY_STATE_ALIVE || joy->cfg_state == JOY_STATE_DYING;
}

ALLEGRO_JOYSTICK_DRIVER* _al_osx_get_joystick_driver_10_5(void)
{
   static ALLEGRO_JOYSTICK_DRIVER* vt = NULL;
   if (vt == NULL) {
      vt = al_malloc(sizeof(*vt));
      memset(vt, 0, sizeof(*vt));
      vt->joydrv_ascii_name = "OSX HID Driver";
      vt->init_joystick = init_joystick;
      vt->exit_joystick = exit_joystick;
      vt->reconfigure_joysticks = reconfigure_joysticks;
      vt->num_joysticks = num_active_joysticks;
      vt->get_joystick = get_joystick;
      vt->release_joystick = release_joystick;
      vt->get_joystick_state = get_joystick_state;
      vt->get_name = get_joystick_name;
      vt->get_active = get_joystick_active;
   }
   return vt;
}

#endif // Leopard+

#ifndef NSAppKitVersionNumber10_5
#define NSAppKitVersionNumber10_5 949
#endif



ALLEGRO_JOYSTICK_DRIVER* _al_osx_get_joystick_driver_10_4(void);
ALLEGRO_JOYSTICK_DRIVER* _al_osx_get_joystick_driver_10_5(void);

ALLEGRO_JOYSTICK_DRIVER* _al_osx_get_joystick_driver(void)
{
   if (floor(NSAppKitVersionNumber) >= NSAppKitVersionNumber10_5) {
   	return _al_osx_get_joystick_driver_10_5();
   }
   else {
   	return _al_osx_get_joystick_driver_10_4();
   }
}

/* Local variables:       */
/* c-basic-offset: 3      */
/* indent-tabs-mode: nil  */
/* End:                   */
