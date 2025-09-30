#!/usr/bin/env python3
import time
import notify2

def get_inputs():
    try:
        set_timer = input("Timer: ").split()

        in1 = in2 = 0
        time_minute_or_second1 = time_minute_or_second2 = None

        if len(set_timer) >= 2:
            in1 = int(set_timer[0])
            time_minute_or_second1 = set_timer[1]

        if len(set_timer) >= 4:
            in2 = int(set_timer[2])
            time_minute_or_second2 = set_timer[3]

        return in1, time_minute_or_second1, in2, time_minute_or_second2

    except (ValueError, IndexError):
        print("Please enter a valid input.\nExample: 10 m 2 s")
        return None, None, None, None

def timer(time_processed):
    in1, time_minute_or_second1, in2, time_minute_or_second2 = time_processed
    if time_minute_or_second1 == "m":
        total_seconds = in1*60
    else:
        total_seconds = in1
    if time_minute_or_second2 == "s":
        total_seconds += in2
    else:
        total_seconds = total_seconds
    total_minutes = total_seconds/60
    print(f"Time has been set for {total_minutes} minutes")
    while total_seconds != 0:
        mins, seconds = divmod(total_seconds, 60)
        format = "Time left: {:02d}:{:02d}".format(mins, seconds)
        print(format, end='\r')
        time.sleep(1)
        total_seconds-=1
    print("\ntimes over!")
    notify2.init("Timer.py")
    n = notify2.Notification("Time IS OVER MOOOIIIT!!")
    n.show()
    
        
            

def main():
    time_processed = get_inputs()
    timer(time_processed)

if __name__ == "__main__":
    main()