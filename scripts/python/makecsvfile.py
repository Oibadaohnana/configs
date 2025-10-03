import csv
import os
import click


def make_csv_file(filename, data):
    with open(filename, 'w', newline='') as file:
        writer = csv.writer(file)
        writer.writerows(data)
    return()
    


def main():
    make_csv_file()


if __name__== "__main__":
    main()