//
//  GarageDoor Pebble App
//
//  Created by Dale Low.
//  Copyright (c) 2014 gumbypp consulting. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
// - The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#include <pebble.h>
#include "shared_pebble.h"

#define kTextBtnMessageLen 32
#define kTextDialogMessageLen 64

static Window *g_window;
static char g_text_btn_up_message[kTextBtnMessageLen];
static char g_text_btn_select_message[kTextBtnMessageLen];
static char g_text_btn_down_message[kTextBtnMessageLen];
static TextLayer *g_text_btn_up;
static TextLayer *g_text_btn_select;
static TextLayer *g_text_btn_down;

static Window *g_dialog;
static char g_dialog_message[kTextDialogMessageLen];
static TextLayer *g_text_dialog;

static void push_dialog(const char *message);
static void pop_dialog();

// AppMessage
void out_sent_handler(DictionaryIterator *sent, void *context) 
{
    // outgoing message was delivered
}

void out_failed_handler(DictionaryIterator *failed, AppMessageResult reason, void *context) 
{
    // outgoing message failed
}

void in_received_handler(DictionaryIterator *received, void *context) 
{
    // update button label(s)
    Tuple *text_tuple = dict_find(received, kMessageKeyRxLabelBtnUp);
    if (text_tuple) {
        strncpy(g_text_btn_up_message, text_tuple->value->cstring, kTextBtnMessageLen-1);
        text_layer_set_text(g_text_btn_up, g_text_btn_up_message);
    }

    text_tuple = dict_find(received, kMessageKeyRxLabelBtnSelect);
    if (text_tuple) {
        strncpy(g_text_btn_select_message, text_tuple->value->cstring, kTextBtnMessageLen-1);
        text_layer_set_text(g_text_btn_select, g_text_btn_select_message);
    }

    text_tuple = dict_find(received, kMessageKeyRxLabelBtnDown);
    if (text_tuple) {
        strncpy(g_text_btn_down_message, text_tuple->value->cstring, kTextBtnMessageLen-1);
        text_layer_set_text(g_text_btn_down, g_text_btn_down_message);
    }
}

void in_dropped_handler(AppMessageResult reason, void *context) 
{
    // incoming message dropped
}

// Key events
static void send_command(PebbleCmdType cmd)
{
    DictionaryIterator *iter;
    app_message_outbox_begin(&iter);    
    Tuplet value = TupletInteger(kMessageKeyTxCmd, cmd);
    dict_write_tuplet(iter, &value);    
    app_message_outbox_send();
}

static void up_click_handler(ClickRecognizerRef recognizer, void *context) 
{
    if (g_dialog) {
        pop_dialog();
        return;
    }
    
    text_layer_set_text(g_text_btn_up, "Ping");
    send_command(kPebbleCmdBtnUp);
}

static void select_click_handler(ClickRecognizerRef recognizer, void *context) 
{
    if (g_dialog) {
        pop_dialog();
        return;
    }

    send_command(kPebbleCmdBtnSelect);
}

static void down_click_handler(ClickRecognizerRef recognizer, void *context) 
{
    if (g_dialog) {
        pop_dialog();
        return;
    }

    send_command(kPebbleCmdBtnDown);
}

static void click_config_provider(void *context) 
{
    window_single_click_subscribe(BUTTON_ID_UP, up_click_handler);
    window_single_click_subscribe(BUTTON_ID_SELECT, select_click_handler);
    window_single_click_subscribe(BUTTON_ID_DOWN, down_click_handler);
}

// main window
static void window_load(Window *window) 
{
    Layer *window_layer = window_get_root_layer(window);
    GRect bounds = layer_get_bounds(window_layer);

    g_text_btn_up = text_layer_create(GRect(0, 10, 134, 32));
    text_layer_set_font(g_text_btn_up, fonts_get_system_font(FONT_KEY_GOTHIC_28_BOLD));
    text_layer_set_text(g_text_btn_up, "Ping");
    text_layer_set_text_alignment(g_text_btn_up, GTextAlignmentRight);  
    layer_add_child(window_layer, text_layer_get_layer(g_text_btn_up));

    g_text_btn_select = text_layer_create(GRect(0, 55, 134, 32));
    text_layer_set_font(g_text_btn_select, fonts_get_system_font(FONT_KEY_GOTHIC_28_BOLD));
    text_layer_set_text(g_text_btn_select, "--");
    text_layer_set_text_alignment(g_text_btn_select, GTextAlignmentRight);  
    layer_add_child(window_layer, text_layer_get_layer(g_text_btn_select));

    g_text_btn_down = text_layer_create(GRect(0, 100, 134, 32));
    text_layer_set_font(g_text_btn_down, fonts_get_system_font(FONT_KEY_GOTHIC_28_BOLD));
    text_layer_set_text(g_text_btn_down, "--");
    text_layer_set_text_alignment(g_text_btn_down, GTextAlignmentRight);  
    layer_add_child(window_layer, text_layer_get_layer(g_text_btn_down));
}

static void window_unload(Window *window) 
{
    text_layer_destroy(g_text_btn_down);
    text_layer_destroy(g_text_btn_select);
    text_layer_destroy(g_text_btn_up);
}

// dialog
static void dialog_load(Window *dialog) 
{
    Layer *window_layer = window_get_root_layer(dialog);
    GRect bounds = layer_get_bounds(window_layer);
    
    g_text_dialog = text_layer_create(GRect(0, 10, 134, 148));
    text_layer_set_font(g_text_dialog, fonts_get_system_font(FONT_KEY_GOTHIC_28_BOLD));
    text_layer_set_text(g_text_dialog, g_dialog_message);
    text_layer_set_text_alignment(g_text_dialog, GTextAlignmentCenter);  
    layer_add_child(window_layer, text_layer_get_layer(g_text_dialog));
}

static void dialog_unload(Window *dialog) 
{
    text_layer_destroy(g_text_dialog);

    g_dialog = NULL;
}

static void push_dialog(const char *message)
{
    if (g_dialog) {
        return;
    }
    
    strncpy(g_dialog_message, message, kTextDialogMessageLen-1);

    g_dialog = window_create();
    window_set_click_config_provider(g_dialog, click_config_provider);
    window_set_window_handlers(g_dialog, (WindowHandlers) {
        .load = dialog_load,
        .unload = dialog_unload,
    });

    window_stack_push(g_dialog, true);
}

static void pop_dialog()
{
    if (g_dialog) {
        window_stack_pop(true);
        window_destroy(g_dialog);        
    }
}

// main
static void init(void) 
{
    const uint32_t inbound_size = 64;
    const uint32_t outbound_size = 64;

    app_message_register_inbox_received(in_received_handler);
    app_message_register_inbox_dropped(in_dropped_handler);
    app_message_register_outbox_sent(out_sent_handler);
    app_message_register_outbox_failed(out_failed_handler);
    app_message_open(inbound_size, outbound_size);

    g_window = window_create();
    window_set_click_config_provider(g_window, click_config_provider);
    window_set_window_handlers(g_window, (WindowHandlers) {
        .load = window_load,
        .unload = window_unload,
    });
    const bool animated = true;
    window_stack_push(g_window, animated);
}

static void deinit(void) 
{
    window_destroy(g_window);
}

int main(void) 
{
    init();
    app_event_loop();
    deinit();
}
