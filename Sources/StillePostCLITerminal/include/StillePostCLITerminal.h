#ifndef STILLE_POST_CLI_TERMINAL_H
#define STILLE_POST_CLI_TERMINAL_H

#include <termios.h>

typedef enum {
    SP_TERMINAL_NOT_TTY,
    SP_TERMINAL_ECHO_DISABLED,
    SP_TERMINAL_ECHO_FAILED
} SPTerminalEchoResult;

// settings muss bis zur Wiederherstellung des Echos gültig bleiben.
SPTerminalEchoResult sp_terminal_disable_echo(struct termios *settings);
int sp_terminal_restore_echo(void);

#endif
