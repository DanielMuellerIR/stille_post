#include "StillePostCLITerminal.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>

_Static_assert(ATOMIC_POINTER_LOCK_FREE == 2, "Terminal-Signalhandler braucht lock-freie Zeiger");
static atomic_flag terminalLock = ATOMIC_FLAG_INIT;
static _Atomic(struct termios *) restoreSettings;
static const int terminalSignals[] = { SIGINT, SIGTERM, SIGPIPE };
enum { terminalSignalCount = sizeof(terminalSignals) / sizeof(terminalSignals[0]) };
static struct sigaction savedActions[terminalSignalCount];

static void guardedSignals(sigset_t *signals) {
    sigemptyset(signals);
    for (int index = 0; index < terminalSignalCount; ++index) {
        sigaddset(signals, terminalSignals[index]);
    }
    sigaddset(signals, SIGTTOU);
}

static void lockTerminal(void) {
    while (atomic_flag_test_and_set_explicit(&terminalLock, memory_order_acquire)) {
        // Der normale Aufrufer hat die Signale blockiert, solange er die
        // Sperre hält. Nur auf einem anderen Thread kann der Handler hier warten.
    }
}

static void unlockTerminal(void) {
    atomic_flag_clear_explicit(&terminalLock, memory_order_release);
}

static int setTerminalAttributes(const struct termios *attributes) {
    int result;
    do {
        result = tcsetattr(STDIN_FILENO, TCSANOW, attributes);
    } while (result < 0 && errno == EINTR);
    return result;
}

static int restoreAttributes(const struct termios *settings) {
    // Verwirft eine angefangene Eingabe. TCSANOW wartet auch bei angehaltener
    // Terminal-Ausgabe nicht auf deren Übertragung.
    (void)tcflush(STDIN_FILENO, TCIFLUSH);
    return setTerminalAttributes(settings);
}

static void restoreSignalActions(int installed) {
    for (int index = 0; index < installed; ++index) {
        (void)sigaction(terminalSignals[index], &savedActions[index], NULL);
    }
    atomic_store_explicit(&restoreSettings, NULL, memory_order_relaxed);
}

static void restoreOnSignal(int signo) {
    lockTerminal();
    const struct termios *settings = atomic_load_explicit(&restoreSettings, memory_order_relaxed);
    if (settings != NULL) {
        (void)restoreAttributes(settings);
    }

    // Der Prozess endet durch das ursprüngliche Signal, auch für Eltern,
    // die per waitpid zwischen Signal und regulärem Exit unterscheiden.
    struct sigaction defaultAction = { .sa_handler = SIG_DFL };
    sigemptyset(&defaultAction.sa_mask);
    sigset_t terminatingSignal;
    sigemptyset(&terminatingSignal);
    sigaddset(&terminatingSignal, signo);
    if (sigaction(signo, &defaultAction, NULL) == 0
        && pthread_sigmask(SIG_UNBLOCK, &terminatingSignal, NULL) == 0) {
        (void)raise(signo);
    }
    _exit(128 + signo);
}

SPTerminalEchoResult sp_terminal_disable_echo(struct termios *settings) {
    if (!isatty(STDIN_FILENO)) {
        return SP_TERMINAL_NOT_TTY;
    }

    struct sigaction action = { .sa_handler = restoreOnSignal };
    guardedSignals(&action.sa_mask);
    sigset_t previousMask;
    if (pthread_sigmask(SIG_BLOCK, &action.sa_mask, &previousMask) != 0) {
        return SP_TERMINAL_ECHO_FAILED;
    }

    // Den Zustand veröffentlichen, bevor das Echo abgeschaltet wird. Auf
    // anderen Threads zugestellte Signale warten bis nach der Änderung.
    lockTerminal();
    SPTerminalEchoResult result = SP_TERMINAL_ECHO_FAILED;
    if (tcgetattr(STDIN_FILENO, settings) == 0) {
        int installed = 0;
        while (installed < terminalSignalCount
            && sigaction(terminalSignals[installed], &action, &savedActions[installed]) == 0) {
            ++installed;
        }
        if (installed != terminalSignalCount) {
            restoreSignalActions(installed);
        } else {
            struct termios hidden = *settings;
            hidden.c_lflag &= ~(ECHO | ECHONL);
            atomic_store_explicit(&restoreSettings, settings, memory_order_relaxed);
            if (tcflush(STDIN_FILENO, TCIFLUSH) == 0 && setTerminalAttributes(&hidden) == 0) {
                result = SP_TERMINAL_ECHO_DISABLED;
            } else if (restoreAttributes(settings) == 0) {
                restoreSignalActions(installed);
            }
        }
    }
    unlockTerminal();
    (void)pthread_sigmask(SIG_SETMASK, &previousMask, NULL);
    return result;
}

int sp_terminal_restore_echo(void) {
    sigset_t signals;
    sigset_t previousMask;
    guardedSignals(&signals);
    if (pthread_sigmask(SIG_BLOCK, &signals, &previousMask) != 0) {
        return -1;
    }

    lockTerminal();
    const struct termios *settings = atomic_load_explicit(&restoreSettings, memory_order_relaxed);
    int result = 0;
    if (settings != NULL) {
        result = restoreAttributes(settings);
        if (result == 0) {
            restoreSignalActions(terminalSignalCount);
        }
    }
    unlockTerminal();
    (void)pthread_sigmask(SIG_SETMASK, &previousMask, NULL);
    return result;
}
